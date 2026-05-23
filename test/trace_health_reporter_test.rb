# frozen_string_literal: true

require_relative "test_helper"
require "flare/metric_storage"
require "flare/trace_health_reporter"

class TraceHealthReporterTest < Minitest::Test
  def setup
    @storage = Flare::MetricStorage.new
    @processor = MockProcessor.new
    @pool = MockPool.new
    @exporter = MockExporter.new
    @reporter = Flare::TraceHealthReporter.new(
      processor: @processor,
      pool: @pool,
      exporter: @exporter
    )
  end

  def test_records_counter_deltas_and_buffer_gauges
    @processor.dropped_count.value = 3
    @processor.failed_export_count.value = 2
    @processor.exception_count.value = 1
    @processor.buffer_size_value = 12
    @processor.buffer_high_watermark.value = 20
    @pool.empty_count.value = 4
    @pool.expired_count.value = 5
    @exporter.put_failure_count.value = 6
    @exporter.notify_failure_count.value = 7
    @exporter.pool_empty_count.value = 8
    @exporter.exception_count.value = 9

    @reporter.record(@storage, bucket: Time.utc(2026, 5, 22, 12, 34, 56))
    drained = @storage.drain

    assert_equal({ count: 3, sum_ms: 0, error_count: 0 }, drained[key("dropped_spans")])
    assert_equal({ count: 2, sum_ms: 0, error_count: 0 }, drained[key("export_failures")])
    assert_equal({ count: 1, sum_ms: 0, error_count: 0 }, drained[key("processor_exceptions")])
    assert_equal({ count: 4, sum_ms: 0, error_count: 0 }, drained[key("upload_url_pool_empty")])
    assert_equal({ count: 5, sum_ms: 0, error_count: 0 }, drained[key("upload_url_expired")])
    assert_equal({ count: 6, sum_ms: 0, error_count: 0 }, drained[key("r2_put_failures")])
    assert_equal({ count: 7, sum_ms: 0, error_count: 0 }, drained[key("notify_failures")])
    assert_equal({ count: 8, sum_ms: 0, error_count: 0 }, drained[key("trace_pool_empty")])
    assert_equal({ count: 9, sum_ms: 0, error_count: 0 }, drained[key("trace_export_exceptions")])
    assert_equal({ count: 1, sum_ms: 12, error_count: 0 }, drained[key("buffer_size")])
    assert_equal({ count: 1, sum_ms: 20, error_count: 0 }, drained[key("buffer_high_watermark")])
    assert_equal({ count: 1, sum_ms: 5000, error_count: 0 }, drained[key("buffer_limit")])
    assert_equal 12, @processor.reset_to
  end

  def test_counter_metrics_are_reported_as_deltas
    @processor.dropped_count.value = 3
    @reporter.record(@storage, bucket: Time.utc(2026, 5, 22, 12, 34, 0))
    @storage.drain

    @processor.dropped_count.value = 5
    @reporter.record(@storage, bucket: Time.utc(2026, 5, 22, 12, 35, 0))
    drained = @storage.drain

    assert_equal({ count: 2, sum_ms: 0, error_count: 0 }, drained[key("dropped_spans", minute: 35)])
  end

  def test_buffer_limit_is_only_reported_when_there_is_buffer_pressure
    @reporter.record(@storage, bucket: Time.utc(2026, 5, 22, 12, 34, 0))
    drained = @storage.drain

    assert_nil drained[key("buffer_limit")]

    @processor.buffer_high_watermark.value = 1
    @reporter.record(@storage, bucket: Time.utc(2026, 5, 22, 12, 35, 0))
    drained = @storage.drain

    assert_equal({ count: 1, sum_ms: 5000, error_count: 0 }, drained[key("buffer_limit", minute: 35)])
  end

  def test_buffer_limit_is_reported_with_nonzero_current_buffer
    @processor.buffer_size_value = 1

    @reporter.record(@storage, bucket: Time.utc(2026, 5, 22, 12, 34, 0))
    drained = @storage.drain

    assert_equal({ count: 1, sum_ms: 5000, error_count: 0 }, drained[key("buffer_limit")])
  end

  private

  def key(operation, minute: 34)
    Flare::MetricKey.new(
      bucket: Time.utc(2026, 5, 22, 12, minute, 0),
      namespace: "sdk",
      service: "flare-ruby",
      target: "tracing",
      operation: operation
    )
  end

  class MockProcessor
    attr_reader :dropped_count, :failed_export_count, :exception_count, :buffer_high_watermark, :max_queue
    attr_accessor :buffer_size_value, :reset_to

    def initialize
      @dropped_count = Concurrent::AtomicFixnum.new(0)
      @failed_export_count = Concurrent::AtomicFixnum.new(0)
      @exception_count = Concurrent::AtomicFixnum.new(0)
      @buffer_high_watermark = Concurrent::AtomicFixnum.new(0)
      @max_queue = 5_000
      @buffer_size_value = 0
      @reset_to = nil
    end

    def buffer_size = @buffer_size_value

    def reset_buffer_high_watermark
      @reset_to = @buffer_size_value
      @buffer_high_watermark.value = @buffer_size_value
    end
  end

  class MockPool
    attr_reader :empty_count, :expired_count

    def initialize
      @empty_count = Concurrent::AtomicFixnum.new(0)
      @expired_count = Concurrent::AtomicFixnum.new(0)
    end
  end

  class MockExporter
    attr_reader :put_failure_count, :notify_failure_count, :pool_empty_count, :exception_count

    def initialize
      @put_failure_count = Concurrent::AtomicFixnum.new(0)
      @notify_failure_count = Concurrent::AtomicFixnum.new(0)
      @pool_empty_count = Concurrent::AtomicFixnum.new(0)
      @exception_count = Concurrent::AtomicFixnum.new(0)
    end
  end
end
