# frozen_string_literal: true

require_relative "test_helper"
require "flare/recording_batch_span_processor"

class RecordingBatchSpanProcessorTest < Minitest::Test
  def setup
    @exporter = RecordingExporter.new
    @processor = Flare::RecordingBatchSpanProcessor.new(
      @exporter,
      schedule_delay: 10,
      max_queue_size: 10,
      max_export_batch_size: 5,
      logger: Logger.new(IO::NULL)
    )
  end

  def teardown
    @processor.shutdown(timeout: 1)
  end

  def test_exports_record_only_spans_without_changing_span_data
    span_data = SpanData.new("trace", false)
    @processor.on_finish(MockSpan.new(span_data))

    assert_equal SUCCESS, @processor.force_flush(timeout: 1)
    assert_same span_data, @exporter.exports.flatten.first
    refute @exporter.exports.flatten.first.trace_flags.sampled?
  end

  def test_exports_asynchronously
    @processor.on_finish(MockSpan.new(SpanData.new("trace", false)))

    wait_until { @exporter.exports.flatten.length == 1 }
    assert_equal 1, @exporter.exports.flatten.length
  end

  def test_force_flush_stays_bounded_when_exporter_ignores_timeout
    exporter = BlockingExporter.new
    processor = Flare::RecordingBatchSpanProcessor.new(exporter, schedule_delay: 60_000)
    processor.on_finish(MockSpan.new(SpanData.new("trace", false)))
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    result = processor.force_flush(timeout: 0.02)

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    assert_equal OpenTelemetry::SDK::Trace::Export::TIMEOUT, result
    assert_operator elapsed, :<, 0.1
  ensure
    exporter&.release
    processor&.shutdown(timeout: 1)
  end

  def test_force_flush_returns_failure_from_export_it_waited_on
    exporter = BlockingExporter.new(result: OpenTelemetry::SDK::Trace::Export::FAILURE)
    processor = Flare::RecordingBatchSpanProcessor.new(
      exporter,
      schedule_delay: 1,
      max_export_batch_size: 1
    )
    processor.on_finish(MockSpan.new(SpanData.new("trace", false)))
    exporter.wait_until_started
    Thread.new { sleep 0.02; exporter.release }

    result = processor.force_flush(timeout: 1)

    assert_equal OpenTelemetry::SDK::Trace::Export::FAILURE, result
  ensure
    exporter&.release
    processor&.shutdown(timeout: 1)
  end

  def test_clears_inherited_buffers_after_fork
    tempfile = Tempfile.new("flare-local-export")
    tempfile.close
    path = tempfile.path
    exporter = RecordingExporter.new(path: path)
    processor = Flare::RecordingBatchSpanProcessor.new(exporter, schedule_delay: 60_000)
    processor.on_finish(MockSpan.new(SpanData.new("parent", false)))

    pid = fork do
      processor.on_finish(MockSpan.new(SpanData.new("child", false)))
      processor.force_flush(timeout: 1)
      exit!
    end
    Process.wait(pid)
    processor.force_flush(timeout: 1)

    assert_equal %w[child parent], File.readlines(path, chomp: true).sort
  ensure
    processor&.shutdown(timeout: 1)
    tempfile&.close!
  end

  private

  SUCCESS = OpenTelemetry::SDK::Trace::Export::SUCCESS
  Flags = Struct.new(:sampled?)
  SpanData = Struct.new(:trace_id, :sampled, keyword_init: false) do
    def trace_flags = Flags.new(sampled)
  end
  MockSpan = Struct.new(:span_data) do
    def to_span_data = span_data
  end

  def wait_until(timeout: 1)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
  end

  class RecordingExporter
    attr_reader :exports

    def initialize(path: nil)
      @exports = []
      @path = path
    end

    def export(spans, timeout: nil)
      @exports << spans
      File.open(@path, "a") { |file| spans.each { |span| file.puts(span.trace_id) } } if @path
      SUCCESS
    end

    def force_flush(timeout: nil) = SUCCESS
    def shutdown(timeout: nil) = SUCCESS
  end

  class BlockingExporter
    def initialize(result: SUCCESS)
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @started = false
      @released = false
      @result = result
    end

    def export(_spans, timeout: nil)
      @mutex.synchronize do
        @started = true
        @condition.broadcast
        @condition.wait(@mutex) until @released
      end
      @result
    end

    def wait_until_started
      @mutex.synchronize { @condition.wait(@mutex) until @started }
    end

    def release
      @mutex.synchronize do
        @released = true
        @condition.broadcast
      end
    end

    def force_flush(timeout: nil) = SUCCESS
    def shutdown(timeout: nil) = SUCCESS
  end
end
