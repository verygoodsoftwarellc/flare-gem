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
      logger:         Logger.new(IO::NULL)
    )
  end

  def teardown
    @processor.shutdown(timeout: 1)
  end

  def test_enqueues_sampled_spans
    @processor.on_finish(span(trace_id: "t1", span_id: "s1", sampled: true))
    @processor.force_flush

    assert_equal 1, @exporter.exports.flatten.length
  end

  def test_enqueues_marked_spans_even_when_not_sampled
    @marker.mark("t1", owner_span_id: "rack", rule_id: 1)
    @processor.on_finish(span(trace_id: "t1", span_id: "child", sampled: false))
    @processor.force_flush

    assert_equal 1, @exporter.exports.flatten.length
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

    5.times { |i| processor.on_finish(span(trace_id: "t#{i}", span_id: "s#{i}", sampled: true)) }
    processor.force_flush
    processor.shutdown(timeout: 1)

    assert_equal 2, processor.dropped_count.value
    exported_ids = @exporter.exports.flatten.map(&:trace_id)
    assert_equal %w[t2 t3 t4], exported_ids
  end

  def test_shutdown_drains_remaining_spans
    @processor.on_finish(span(trace_id: "t1", span_id: "s1", sampled: true))
    @processor.shutdown(timeout: 1)

    assert_equal 1, @exporter.exports.flatten.length
  end

  def test_force_flush_synchronously_exports
    @processor.on_finish(span(trace_id: "t1", span_id: "s1", sampled: true))
    @processor.force_flush

    assert_equal 1, @exporter.exports.flatten.length
  end

  private

  def span(trace_id:, span_id:, sampled:)
    MockSpan.new(trace_id: trace_id, span_id: span_id, sampled: sampled)
  end

  class RecordingExporter
    attr_reader :exports
    attr_accessor :raise_with, :return_failure

    def initialize
      @exports = []
    end

    def export(spans, timeout: nil)
      raise @raise_with if @raise_with
      return OpenTelemetry::SDK::Trace::Export::FAILURE if @return_failure

      @exports << spans
      OpenTelemetry::SDK::Trace::Export::SUCCESS
    end

    def shutdown(timeout: nil); end
  end

  class MockSpan
    SpanData = Struct.new(:trace_id, :span_id, keyword_init: true)

    def initialize(trace_id:, span_id:, sampled:)
      @data = SpanData.new(trace_id: trace_id, span_id: span_id)
      @ctx  = MockContext.new(trace_id, span_id, MockFlags.new(sampled))
    end

    def context = @ctx
    def to_span_data = @data
  end

  MockContext = Struct.new(:trace_id, :span_id, :trace_flags)
  MockFlags   = Struct.new(:sampled?)
end
