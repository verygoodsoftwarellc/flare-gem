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

    DEFAULT_MAX_QUEUE = 512
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

      @queue   = []
      @mutex   = Mutex.new
      @cond    = ConditionVariable.new
      @stopped = false

      @dropped_count       = Concurrent::AtomicFixnum.new(0)
      @failed_export_count = Concurrent::AtomicFixnum.new(0)
      @exception_count     = Concurrent::AtomicFixnum.new(0)

      @worker = Thread.new { worker_loop }
      @worker.name = "flare-filtering-span-processor"
    end

    def on_start(_span, _parent_context); end

    def on_finish(span)
      ctx = span.context
      sampled = ctx&.trace_flags&.sampled?
      marked  = ctx && @marker.marked?(ctx.trace_id)

      # Owner cleanup happens regardless of whether we export.
      if marked && @marker.owner?(ctx.trace_id, ctx.span_id)
        @marker.unmark(ctx.trace_id)
      end

      return unless sampled || marked
      enqueue(span)
    end

    def force_flush(timeout: nil)
      drain_and_export
      SUCCESS
    end

    def shutdown(timeout: nil)
      @mutex.synchronize do
        @stopped = true
        @cond.broadcast
      end
      @worker.join(timeout || 5)
      drain_and_export
      @exporter.shutdown(timeout: timeout) if @exporter.respond_to?(:shutdown)
      SUCCESS
    end

    private

    def enqueue(span)
      span_data = span.respond_to?(:to_span_data) ? span.to_span_data : span

      @mutex.synchronize do
        if @queue.size >= @max_queue
          @queue.shift
          @dropped_count.increment
        end
        @queue << span_data
        @cond.signal if @queue.size >= [@max_queue / 2, 1].max
      end
    end

    def worker_loop
      until stopped?
        @mutex.synchronize do
          @cond.wait(@mutex, @flush_interval) if @queue.empty? && !@stopped
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
        return if @queue.empty?
        batch = @queue
        @queue = []
      end

      result = @exporter.export(batch, timeout: @export_timeout)
      @failed_export_count.increment if result != SUCCESS
    rescue StandardError => e
      @exception_count.increment
      @logger.warn("[Flare::FilteringSpanProcessor] export failed: #{e.class}: #{e.message}")
    end
  end
end
