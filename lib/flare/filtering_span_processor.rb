# frozen_string_literal: true

require "concurrent/atomic/atomic_fixnum"
require "logger"
require "opentelemetry/sdk"

require_relative "deadline"

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
    TIMEOUT = OpenTelemetry::SDK::Trace::Export::TIMEOUT

    DEFAULT_MAX_QUEUE = 5_000
    DEFAULT_FLUSH_INTERVAL = 5      # seconds
    DEFAULT_EXPORT_TIMEOUT = 30     # seconds
    DEFAULT_MARKED_TRACE_GRACE_PERIOD = 1.0 # seconds

    attr_reader :dropped_count, :failed_export_count, :exception_count, :buffer_high_watermark, :max_queue

    def initialize(exporter:, marker:,
                   max_queue: DEFAULT_MAX_QUEUE,
                   flush_interval: DEFAULT_FLUSH_INTERVAL,
                   export_timeout: DEFAULT_EXPORT_TIMEOUT,
                   marked_trace_grace_period: DEFAULT_MARKED_TRACE_GRACE_PERIOD,
                   logger: nil)
      @exporter       = exporter
      @marker         = marker
      @max_queue      = max_queue
      @flush_interval = flush_interval
      @export_timeout = export_timeout
      @marked_trace_grace_period = marked_trace_grace_period.to_f
      @logger         = logger || Logger.new($stderr, level: Logger::WARN)

      @pending_by_trace = {}
      @trace_order      = []
      @pending_count    = 0
      @ready_queue      = []
      @delayed_ready_by_trace = {}
      @mutex            = Mutex.new
      @cond             = ConditionVariable.new
      @stopped          = false
      @active_exports   = 0
      @export_completion_sequence = 0
      @last_export_result = SUCCESS
      @flush_owner      = nil
      @pid              = $$

      @dropped_count       = Concurrent::AtomicFixnum.new(0)
      @failed_export_count = Concurrent::AtomicFixnum.new(0)
      @exception_count     = Concurrent::AtomicFixnum.new(0)
      @buffer_high_watermark = Concurrent::AtomicFixnum.new(0)

      start_worker
    end

    def on_start(_span, _parent_context); end

    def on_finish(span)
      detect_forking

      ctx = span.context
      sampled = ctx&.trace_flags&.sampled?
      marked  = ctx && @marker.marked?(ctx.trace_id)
      owner_finished = marked && @marker.owner?(ctx.trace_id, ctx.span_id)

      return unless sampled || marked

      span_data = span.respond_to?(:to_span_data) ? span.to_span_data : span
      enqueue(
        span_data,
        complete: owner_finished || sampled_completion_span?(span_data),
        delay: owner_finished ? @marked_trace_grace_period : 0
      )
    end

    def force_flush(timeout: nil)
      detect_forking
      deadline = Deadline.new(timeout)
      return TIMEOUT unless begin_flush(deadline)
      prior_result = @flush_prior_result

      batch = snapshot_for_flush(deadline)
      return TIMEOUT unless batch

      operation = start_flush_export(batch, deadline)
      result = wait_for_flush_export(operation, deadline)
      [prior_result, result].max
    ensure
      finish_flush if @flush_owner == Thread.current
    end

    def shutdown(timeout: nil)
      detect_forking
      deadline = Deadline.new(timeout)
      return TIMEOUT unless lock_before_deadline(deadline)

      begin
        @stopped = true
        @cond.broadcast
      ensure
        @mutex.unlock
      end
      @worker.join(deadline.remaining || 5)
      return TIMEOUT if @worker.alive? || deadline.expired?

      result = force_flush(timeout: deadline.remaining)
      return result unless result == SUCCESS
      return TIMEOUT if deadline.expired?

      exporter_result = @exporter.shutdown(timeout: deadline.remaining) if @exporter.respond_to?(:shutdown)
      return TIMEOUT if deadline.expired?

      exporter_result || SUCCESS
    end

    def buffer_size
      @mutex.synchronize { queued_span_count }
    end

    def reset_buffer_high_watermark
      @buffer_high_watermark.value = buffer_size
    end

    private

    def enqueue(span_data, complete:, delay: 0)
      @mutex.synchronize do
        trace_id = span_data.trace_id
        @trace_order << trace_id unless @pending_by_trace.key?(trace_id)
        @pending_by_trace[trace_id] ||= []
        @pending_by_trace[trace_id] << span_data
        @pending_count += 1
        evict_oldest_spans

        if complete
          delay.positive? ? delay_trace_ready(trace_id, delay) : mark_trace_ready(trace_id)
        end
        evict_oldest_spans
        update_buffer_high_watermark
      end
    end

    def worker_loop
      until stopped?
        @mutex.synchronize do
          timeout = next_wait_timeout
          waiting_for_export = @flush_owner || @active_exports.positive?
          @cond.wait(@mutex, timeout) if (@ready_queue.empty? || waiting_for_export) && !@stopped
        end
        drain_and_export
      end
    end

    def stopped?
      @mutex.synchronize { @stopped }
    end

    def drain_and_export
      batch = nil
      @mutex.synchronize do
        promote_due_delayed_traces
        return if @ready_queue.empty? || @flush_owner || @active_exports.positive?

        batch = @ready_queue
        @ready_queue = []
        @active_exports += 1
      end

      result = export_batch(batch, timeout: @export_timeout)
    ensure
      export_finished(result || FAILURE) if batch
    end

    def begin_flush(deadline)
      return false unless lock_before_deadline(deadline)

      begin
        initial_sequence = @export_completion_sequence
        while @flush_owner && @flush_owner != Thread.current
          return false if deadline.expired?

          @cond.wait(@mutex, deadline.remaining)
        end
        @flush_owner = Thread.current

        while @active_exports.positive?
          return false if deadline.expired?

          @cond.wait(@mutex, deadline.remaining)
        end
        @flush_prior_result = if @export_completion_sequence > initial_sequence
          @last_export_result
        else
          SUCCESS
        end
      ensure
        @mutex.unlock
      end
      true
    end

    def finish_flush
      @mutex.synchronize do
        @flush_owner = nil
        @cond.broadcast
      end
    end

    def snapshot_for_flush(deadline)
      return unless lock_before_deadline(deadline)

      begin
        @ready_queue.concat(@pending_by_trace.values.flatten)
        @pending_by_trace.clear
        @trace_order.clear
        @pending_count = 0
        unmark_delayed_traces
        @delayed_ready_by_trace.clear
        batch = @ready_queue
        @ready_queue = []
        batch
      ensure
        @mutex.unlock
      end
    end

    def start_flush_export(batch, deadline)
      operation = { done: false, result: nil }
      @mutex.synchronize { @active_exports += 1 }
      Thread.new do
        result = batch.empty? ? SUCCESS : export_batch(batch, timeout: deadline.remaining)
        if result == SUCCESS && !deadline.expired? && @exporter.respond_to?(:force_flush)
          result = @exporter.force_flush(timeout: deadline.remaining)
        end
        result = TIMEOUT if deadline.expired?
        operation[:result] = result
      rescue StandardError => e
        @exception_count.increment
        @logger.warn("[Flare::FilteringSpanProcessor] force flush failed: #{e.class}: #{e.message}")
        operation[:result] = FAILURE
      ensure
        @mutex.synchronize do
          operation[:done] = true
          complete_export(operation[:result])
        end
      end
      operation
    end

    def wait_for_flush_export(operation, deadline)
      @mutex.synchronize do
        until operation[:done]
          return TIMEOUT if deadline.expired?

          @cond.wait(@mutex, deadline.remaining)
        end
      end
      operation[:result]
    end

    def export_batch(batch, timeout:)
      result = @exporter.export(batch, timeout: timeout)
      @failed_export_count.increment if result != SUCCESS
      result
    rescue StandardError => e
      @exception_count.increment
      @logger.warn("[Flare::FilteringSpanProcessor] export failed: #{e.class}: #{e.message}")
      FAILURE
    end

    def export_finished(result)
      @mutex.synchronize do
        complete_export(result)
      end
    end

    def complete_export(result)
      @active_exports -= 1
      @export_completion_sequence += 1
      @last_export_result = result || FAILURE
      @cond.broadcast
    end

    def lock_before_deadline(deadline)
      return @mutex.lock unless deadline.remaining

      until @mutex.try_lock
        return false if deadline.expired?

        sleep([deadline.remaining, 0.001].min)
      end
      true
    end

    def mark_trace_ready(trace_id)
      batch = @pending_by_trace.delete(trace_id)
      return unless batch

      @trace_order.delete(trace_id)
      @delayed_ready_by_trace.delete(trace_id)
      @pending_count -= batch.length
      @ready_queue.concat(batch)
      @cond.signal
    end

    def delay_trace_ready(trace_id, delay)
      @delayed_ready_by_trace[trace_id] = monotonic_now + delay
      @cond.signal
    end

    def promote_due_delayed_traces
      now = monotonic_now
      ready_trace_ids = @delayed_ready_by_trace.select { |_, ready_at| ready_at <= now }.keys
      ready_trace_ids.each do |trace_id|
        mark_trace_ready(trace_id)
        @marker.unmark(trace_id)
      end
    end

    def unmark_delayed_traces
      @delayed_ready_by_trace.each_key { |trace_id| @marker.unmark(trace_id) }
    end

    def next_wait_timeout
      next_ready_at = @delayed_ready_by_trace.values.min
      return @flush_interval unless next_ready_at

      [next_ready_at - monotonic_now, 0].max
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

    def update_buffer_high_watermark
      current = queued_span_count
      @buffer_high_watermark.update { |previous| current > previous ? current : previous }
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
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

      # The child only retains the forking thread. Replace synchronization
      # objects so it cannot inherit locks or active-export bookkeeping owned
      # by vanished threads.
      @pid = $$
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @pending_by_trace = {}
      @trace_order = []
      @ready_queue = []
      @delayed_ready_by_trace = {}
      @pending_count = 0
      @active_exports = 0
      @export_completion_sequence = 0
      @last_export_result = SUCCESS
      @flush_prior_result = SUCCESS
      @flush_owner = nil
      @stopped = false
      @worker = nil
      start_worker
    end

    def start_worker
      return if @worker&.alive?

      @worker = Thread.new { worker_loop }
      @worker.name = "flare-filtering-span-processor"
    end
  end
end
