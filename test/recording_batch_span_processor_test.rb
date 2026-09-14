# frozen_string_literal: true

require_relative "test_helper"
require "flare/recording_batch_span_processor"
require "tempfile"

class RecordingBatchSpanProcessorTest < Minitest::Test
  SUCCESS = OpenTelemetry::SDK::Trace::Export::SUCCESS

  def setup
    @exporter = RecordingExporter.new
    @processor = Flare::RecordingBatchSpanProcessor.new(
      @exporter,
      max_queue_size: 10,
      max_export_batch_size: 5,
      schedule_delay: 60_000
    )
  end

  def teardown
    @processor&.shutdown(timeout: 1)
  end

  def test_exports_sampled_and_unsampled_recording_spans_unchanged
    sampled = span(sampled: true, name: "sampled")
    unsampled = span(sampled: false, name: "record-only")

    @processor.on_finish(sampled)
    @processor.on_finish(unsampled)
    assert_equal SUCCESS, @processor.force_flush

    assert_equal [sampled.to_span_data, unsampled.to_span_data], @exporter.exports.flatten
  end

  def test_bounded_queue_drops_oldest_spans_on_overflow
    processor = Flare::RecordingBatchSpanProcessor.new(
      @exporter,
      max_queue_size: 3,
      max_export_batch_size: 3,
      schedule_delay: 60_000
    )

    5.times { |index| processor.on_finish(span(sampled: false, name: "span-#{index}")) }
    processor.force_flush
    processor.shutdown(timeout: 1)

    assert_equal %w[span-2 span-3 span-4], @exporter.exports.flatten.map(&:name)
  ensure
    processor&.shutdown(timeout: 1)
  end

  def test_shutdown_drains_remaining_spans_and_shuts_down_exporter
    @processor.on_finish(span(sampled: false, name: "pending"))

    assert_equal SUCCESS, @processor.shutdown(timeout: 1)

    assert_equal ["pending"], @exporter.exports.flatten.map(&:name)
    assert @exporter.shutdown?
  end

  def test_restarts_worker_after_fork
    skip "fork is not supported" unless Process.respond_to?(:fork)

    exporter = RecordingExporter.new(path: Tempfile.new("flare-local-export").path)
    processor = Flare::RecordingBatchSpanProcessor.new(
      exporter,
      max_queue_size: 10,
      max_export_batch_size: 1,
      schedule_delay: 50
    )

    pid = fork do
      processor.on_finish(span(sampled: false, name: "child"))
      sleep 0.15
      exit!
    end
    Process.wait(pid)

    assert_equal 1, File.readlines(exporter.path).length
  ensure
    processor&.shutdown(timeout: 1)
    FileUtils.rm_f(exporter&.path)
  end

  def test_clears_inherited_buffers_after_fork
    skip "fork is not supported" unless Process.respond_to?(:fork)

    exporter = RecordingExporter.new(path: Tempfile.new("flare-local-export").path)
    processor = Flare::RecordingBatchSpanProcessor.new(
      exporter,
      max_queue_size: 10,
      max_export_batch_size: 10,
      schedule_delay: 60_000
    )
    processor.on_finish(span(sampled: false, name: "parent"))

    pid = fork do
      processor.on_finish(span(sampled: false, name: "child"))
      processor.force_flush
      exit!
    end
    Process.wait(pid)
    processor.force_flush

    exported_span_count = File.readlines(exporter.path).map(&:to_i).sum
    assert_equal 2, exported_span_count
  ensure
    processor&.shutdown(timeout: 1)
    FileUtils.rm_f(exporter&.path)
  end

  private

  def span(sampled:, name:)
    MockSpan.new(sampled: sampled, name: name)
  end

  class RecordingExporter
    attr_reader :exports, :path

    def initialize(path: nil)
      @exports = []
      @path = path
      @shutdown = false
    end

    def export(spans, timeout: nil)
      @exports << spans
      File.open(@path, "a") { |file| file.puts(spans.length) } if @path
      SUCCESS
    end

    def force_flush(timeout: nil)
      SUCCESS
    end

    def shutdown(timeout: nil)
      @shutdown = true
      SUCCESS
    end

    def shutdown?
      @shutdown
    end
  end

  class MockSpan
    SpanData = Struct.new(:name, keyword_init: true)
    Context = Struct.new(:trace_flags, keyword_init: true)

    attr_reader :context

    def initialize(sampled:, name:)
      flags = sampled ? OpenTelemetry::Trace::TraceFlags::SAMPLED : OpenTelemetry::Trace::TraceFlags::DEFAULT
      @context = Context.new(trace_flags: flags)
      @span_data = SpanData.new(name: name)
    end

    def to_span_data
      @span_data
    end
  end
end
