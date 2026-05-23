# frozen_string_literal: true

require_relative "test_helper"
require "flare/marker"
require "flare/filtering_span_processor"

class FilteringSpanProcessorTest < Minitest::Test
  def setup
    @marker   = Flare::Marker.new
    @exporter = RecordingExporter.new
    @processor = Flare::FilteringSpanProcessor.new(
      exporter:       @exporter,
      marker:         @marker,
      flush_interval: 0.05,
      marked_trace_grace_period: 0.05,
      logger:         Logger.new(IO::NULL)
    )
  end

  def teardown
    @processor.shutdown(timeout: 1)
  end

  def test_enqueues_sampled_spans
    @processor.on_finish(span(trace_id: "t1", span_id: "s1", sampled: true, parent_span_id: nil))
    @processor.force_flush

    assert_equal 1, @exporter.exports.flatten.length
  end

  def test_holds_sampled_child_spans_until_the_trace_completion_span_finishes
    @processor.on_finish(span(trace_id: "t1", span_id: "child", sampled: true, parent_span_id: "root"))
    sleep 0.1

    assert_empty @exporter.exports

    @processor.on_finish(span(trace_id: "t1", span_id: "root", sampled: true, parent_span_id: nil))
    @processor.force_flush

    exported_ids = @exporter.exports.flatten.map(&:span_id)
    assert_equal %w[child root], exported_ids
  end

  def test_enqueues_marked_spans_when_the_owner_span_finishes
    @marker.mark("t1", owner_span_id: "rack", rule_id: 1)
    @processor.on_finish(span(trace_id: "t1", span_id: "child", sampled: false))

    sleep 0.1
    assert_empty @exporter.exports

    @processor.on_finish(span(trace_id: "t1", span_id: "rack", sampled: false))
    @processor.force_flush

    assert_equal 2, @exporter.exports.flatten.length
  end

  def test_keeps_marked_trace_open_briefly_for_late_finishing_children
    @marker.mark("t1", owner_span_id: "rack", rule_id: 1)

    @processor.on_finish(span(trace_id: "t1", span_id: "rack", sampled: false, parent_span_id: "remote"))
    @processor.on_finish(span(trace_id: "t1", span_id: "late-child", sampled: false, parent_span_id: "rack"))
    wait_until { @exporter.exports.flatten.length == 2 }

    assert_equal %w[rack late-child], @exporter.exports.flatten.map(&:span_id)
    refute @marker.marked?("t1")
  end

  def test_drops_spans_that_are_neither_sampled_nor_marked
    @processor.on_finish(span(trace_id: "t1", span_id: "s1", sampled: false))
    @processor.force_flush

    assert_empty @exporter.exports
  end

  def test_unmarks_when_the_owner_span_finishes
    @marker.mark("t1", owner_span_id: "rack", rule_id: 1)
    assert @marker.marked?("t1")

    @processor.on_finish(span(trace_id: "t1", span_id: "rack", sampled: false))
    @processor.force_flush

    refute @marker.marked?("t1")
  end

  def test_does_not_unmark_when_a_non_owner_span_finishes
    @marker.mark("t1", owner_span_id: "rack", rule_id: 1)

    @processor.on_finish(span(trace_id: "t1", span_id: "child", sampled: false))

    assert @marker.marked?("t1")
  end

  def test_rescues_exporter_exceptions_and_counts_them
    @exporter.raise_with = RuntimeError.new("boom")
    @processor.on_finish(span(trace_id: "t1", span_id: "s1", sampled: true))
    @processor.force_flush

    assert_equal 1, @processor.exception_count.value
  end

  def test_counts_export_failures_separately_from_exceptions
    @exporter.return_failure = true
    @processor.on_finish(span(trace_id: "t1", span_id: "s1", sampled: true))
    @processor.force_flush

    assert_equal 1, @processor.failed_export_count.value
    assert_equal 0, @processor.exception_count.value
  end

  def test_bounded_queue_drops_oldest_on_overflow
    processor = Flare::FilteringSpanProcessor.new(
      exporter:       @exporter,
      marker:         @marker,
      max_queue:      3,
      flush_interval: 60, # don't auto-flush during the test
      logger:         Logger.new(IO::NULL)
    )

    5.times { |i| processor.on_finish(span(trace_id: "t#{i}", span_id: "s#{i}", sampled: true, parent_span_id: "root")) }
    processor.force_flush
    processor.shutdown(timeout: 1)

    assert_equal 2, processor.dropped_count.value
    exported_ids = @exporter.exports.flatten.map(&:trace_id)
    assert_equal %w[t2 t3 t4], exported_ids
  end

  def test_shutdown_drains_remaining_spans
    @processor.on_finish(span(trace_id: "t1", span_id: "s1", sampled: true, parent_span_id: "root"))
    @processor.shutdown(timeout: 1)

    assert_equal 1, @exporter.exports.flatten.length
  end

  def test_force_flush_synchronously_exports
    @processor.on_finish(span(trace_id: "t1", span_id: "s1", sampled: true, parent_span_id: "root"))
    @processor.force_flush

    assert_equal 1, @exporter.exports.flatten.length
  end

  def test_restarts_worker_after_fork
    exporter = RecordingExporter.new(path: Tempfile.new("flare-trace-export").path)
    processor = Flare::FilteringSpanProcessor.new(
      exporter:       exporter,
      marker:         @marker,
      flush_interval: 0.05,
      logger:         Logger.new(IO::NULL)
    )

    pid = fork do
      processor.on_finish(span(trace_id: "t1", span_id: "s1", sampled: true, parent_span_id: nil))
      sleep 0.15
      exit!
    end
    Process.wait(pid)
    processor.shutdown(timeout: 1)

    assert_equal 1, File.readlines(exporter.path).length
  ensure
    processor&.shutdown(timeout: 1)
    FileUtils.rm_f(exporter&.path)
  end

  # Without buffer clearing on fork, the child inherits the parent's pending
  # spans and re-exports them — producing duplicate R2 uploads.
  def test_clears_inherited_buffers_after_fork
    exporter = RecordingExporter.new(path: Tempfile.new("flare-trace-export").path)
    processor = Flare::FilteringSpanProcessor.new(
      exporter:       exporter,
      marker:         @marker,
      flush_interval: 60,
      logger:         Logger.new(IO::NULL)
    )

    processor.on_finish(span(trace_id: "t1", span_id: "child", sampled: true, parent_span_id: "root"))

    pid = fork do
      processor.on_finish(span(trace_id: "t2", span_id: "s2", sampled: true, parent_span_id: nil))
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

  def wait_until(timeout: 1)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
  end

  def span(trace_id:, span_id:, sampled:, parent_span_id: "parent", kind: :internal)
    MockSpan.new(trace_id: trace_id, span_id: span_id, parent_span_id: parent_span_id, sampled: sampled, kind: kind)
  end

  class RecordingExporter
    attr_reader :exports
    attr_reader :path
    attr_accessor :raise_with, :return_failure

    def initialize(path: nil)
      @exports = []
      @path = path
    end

    def export(spans, timeout: nil)
      raise @raise_with if @raise_with
      return OpenTelemetry::SDK::Trace::Export::FAILURE if @return_failure

      @exports << spans
      File.open(@path, "a") { |f| f.puts(spans.length) } if @path
      OpenTelemetry::SDK::Trace::Export::SUCCESS
    end

    def shutdown(timeout: nil); end
  end

  class MockSpan
    SpanData = Struct.new(:trace_id, :span_id, :parent_span_id, :kind, keyword_init: true)

    def initialize(trace_id:, span_id:, parent_span_id:, sampled:, kind:)
      @data = SpanData.new(trace_id: trace_id, span_id: span_id, parent_span_id: parent_span_id, kind: kind)
      @ctx  = MockContext.new(trace_id, span_id, MockFlags.new(sampled))
    end

    def context = @ctx
    def to_span_data = @data
  end

  MockContext = Struct.new(:trace_id, :span_id, :trace_flags)
  MockFlags   = Struct.new(:sampled?)
end
