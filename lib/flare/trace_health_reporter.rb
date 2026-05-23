# frozen_string_literal: true

require_relative "metric_key"

module Flare
  # Records client-side tracing health into MetricStorage so flare-web can
  # warn when local buffering, URL exhaustion, or export errors reduce trace
  # fidelity.
  class TraceHealthReporter
    NAMESPACE = "sdk"
    SERVICE = "flare-ruby"
    TARGET = "tracing"

    def initialize(processor:, pool:, exporter:)
      @processor = processor
      @pool = pool
      @exporter = exporter
      @last = {}
      @mutex = Mutex.new
    end

    def record(storage, bucket: Time.now.utc)
      @mutex.synchronize do
        record_counter(storage, bucket, "dropped_spans", @processor.dropped_count.value)
        record_counter(storage, bucket, "export_failures", @processor.failed_export_count.value)
        record_counter(storage, bucket, "processor_exceptions", @processor.exception_count.value)

        record_counter(storage, bucket, "upload_url_pool_empty", @pool.empty_count.value)
        record_counter(storage, bucket, "upload_url_expired", @pool.expired_count.value)

        record_counter(storage, bucket, "r2_put_failures", @exporter.put_failure_count.value)
        record_counter(storage, bucket, "notify_failures", @exporter.notify_failure_count.value)
        record_counter(storage, bucket, "trace_pool_empty", @exporter.pool_empty_count.value)
        record_counter(storage, bucket, "trace_export_exceptions", @exporter.exception_count.value)

        buffer_size = @processor.buffer_size
        buffer_high_watermark = @processor.buffer_high_watermark.value
        record_gauge(storage, bucket, "buffer_size", buffer_size)
        record_gauge(storage, bucket, "buffer_high_watermark", buffer_high_watermark)
        record_gauge(storage, bucket, "buffer_limit", @processor.max_queue) if buffer_size.positive? || buffer_high_watermark.positive?
        @processor.reset_buffer_high_watermark
      end
    end

    private

    def record_counter(storage, bucket, operation, current)
      previous = @last.fetch(operation, 0)
      @last[operation] = current
      delta = current - previous
      return unless delta.positive?

      storage.add(key(bucket, operation), count: delta, sum_ms: 0, error_count: 0)
    end

    def record_gauge(storage, bucket, operation, value)
      storage.add(key(bucket, operation), count: 1, sum_ms: value, error_count: 0)
    end

    def key(bucket, operation)
      MetricKey.new(
        bucket: bucket_time(bucket),
        namespace: NAMESPACE,
        service: SERVICE,
        target: TARGET,
        operation: operation
      )
    end

    def bucket_time(time)
      Time.utc(time.year, time.month, time.day, time.hour, time.min, 0)
    end
  end
end
