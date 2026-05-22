# frozen_string_literal: true

require "concurrent/atomic/atomic_fixnum"
require "logger"
require "opentelemetry/sdk"

module Flare
  # BSP-shaped span processor whose filter is `sampled OR marked` instead
  # of BSP's `sampled` (BSP early-returns on RECORD_ONLY spans -- our
  # Path 2 spans have sampled=false so they'd be dropped). Forwards
  # matching spans to a trace exporter on a background worker thread so
  # the exporter never runs on the request/job thread (CAF-3).
  #
  # On every on_finish we also check marker.owner?(trace_id, span_id) and
  # unmark when the owning rack span finishes (CAF-2). Cleanup runs even
  # for spans we don't export.
  class FilteringSpanProcessor
    SUCCESS = OpenTelemetry::SDK::Trace::Export::SUCCESS
    FAILURE = OpenTelemetry::SDK::Trace::Export::FAILURE

    DEFAULT_MAX_QUEUE = 5_000
    DEFAULT_FLUSH_INTERVAL = 5      # seconds
    DEFAULT_EXPORT_TIMEOUT = 30     # seconds

    attr_reader :dropped_count, :failed_export_count, :exception_count

    def initialize(exporter:, marker:,
                   max_queue: DEFAULT_MAX_QUEUE,
                   flush_interval: DEFAULT_FLUSH_INTERVAL,
                   export_timeout: DEFAULT_EXPORT_TIMEOUT,
                   logger: nil)
      @exporter       = exporter
      @marker         = marker
      @max_queue      = max_queue
      @flush_interval = flush_interval
      @export_timeout = export_timeout
      @logger         = logger || Logger.new($stderr, level: Logger::WARN)

      @pending_by_trace = {}
      @trace_order      = []
      @pending_count    = 0
      @ready_queue      = []
      @mutex            = Mutex.new
      @cond             = ConditionVariable.new
      @stopped          = false
      @pid              = $$

      @dropped_count       = Concurrent::AtomicFixnum.new(0)
      @failed_export_count = Concurrent::AtomicFixnum.new(0)
      @exception_count     = Concurrent::AtomicFixnum.new(0)

      start_worker
    end

    def on_start(_span, _parent_context); end

    def on_finish(span)
      detect_forking

      ctx = span.context
      sampled = ctx&.trace_flags&.sampled?
      marked  = ctx && @marker.marked?(ctx.trace_id)
      owner_finished = marked && @marker.owner?(ctx.trace_id, ctx.span_id)

      # Owner cleanup happens regardless of whether we export.
      @marker.unmark(ctx.trace_id) if owner_finished

      return unless sampled || marked

      span_data = span.respond_to?(:to_span_data) ? span.to_span_data : span
      enqueue(span_data, complete: owner_finished || sampled_completion_span?(span_data))
    end

    def force_flush(timeout: nil)
      drain_and_export(include_pending: true)
      SUCCESS
    end

    def shutdown(timeout: nil)
      @mutex.synchronize do
        @stopped = true
        @cond.broadcast
      end
      @worker.join(timeout || 5)
      drain_and_export(include_pending: true)
      @exporter.shutdown(timeout: timeout) if @exporter.respond_to?(:shutdown)
      SUCCESS
    end

    private

    def enqueue(span_data, complete:)
      @mutex.synchronize do
        trace_id = span_data.trace_id
        @trace_order << trace_id unless @pending_by_trace.key?(trace_id)
        @pending_by_trace[trace_id] ||= []
        @pending_by_trace[trace_id] << span_data
        @pending_count += 1
        evict_oldest_spans

        mark_trace_ready(trace_id) if complete
        evict_oldest_spans
      end
    end

    def worker_loop
      until stopped?
        @mutex.synchronize do
          @cond.wait(@mutex, @flush_interval) if @ready_queue.empty? && !@stopped
        end
        drain_and_export
      end
    end

    def stopped?
      @mutex.synchronize { @stopped }
    end

    def drain_and_export(include_pending: false)
      batch = nil
      @mutex.synchronize do
        if include_pending
          @ready_queue.concat(@pending_by_trace.values.flatten)
          @pending_by_trace.clear
          @trace_order.clear
          @pending_count = 0
        end

        return if @ready_queue.empty?
        batch = @ready_queue
        @ready_queue = []
      end

      result = @exporter.export(batch, timeout: @export_timeout)
      @failed_export_count.increment if result != SUCCESS
    rescue StandardError => e
      @exception_count.increment
      @logger.warn("[Flare::FilteringSpanProcessor] export failed: #{e.class}: #{e.message}")
    end

    def mark_trace_ready(trace_id)
      batch = @pending_by_trace.delete(trace_id)
      return unless batch

      @trace_order.delete(trace_id)
      @pending_count -= batch.length
      @ready_queue.concat(batch)
      @cond.signal
    end

    def evict_oldest_spans
      while queued_span_count > @max_queue
        trace_id = @trace_order.first
        unless trace_id
          @ready_queue.shift
          @dropped_count.increment
          next
        end

        spans = @pending_by_trace[trace_id]
        if spans.nil? || spans.empty?
          @trace_order.shift
          next
        end

        spans.shift
        @pending_count -= 1
        @dropped_count.increment

        if spans.empty?
          @pending_by_trace.delete(trace_id)
          @trace_order.shift
        end
      end
    end

    def queued_span_count
      @pending_count + @ready_queue.length
    end

    def sampled_completion_span?(span_data)
      root_span?(span_data) || entry_span?(span_data)
    end

    def root_span?(span_data)
      parent_id = span_data.parent_span_id if span_data.respond_to?(:parent_span_id)
      parent_id.nil? ||
        (parent_id.respond_to?(:empty?) && parent_id.empty?) ||
        parent_id == OpenTelemetry::Trace::INVALID_SPAN_ID
    end

    def entry_span?(span_data)
      return false unless span_data.respond_to?(:kind)

      span_data.kind == :server || span_data.kind == :consumer
    end

    def detect_forking
      return if @pid == $$

      @mutex.synchronize do
        return if @pid == $$

        @pid = $$
        @stopped = false
        start_worker
      end
    end

    def start_worker
      return if @worker&.alive?

      @worker = Thread.new { worker_loop }
      @worker.name = "flare-filtering-span-processor"
    end
  end
end
