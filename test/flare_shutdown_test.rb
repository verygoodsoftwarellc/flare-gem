# frozen_string_literal: true

require_relative "test_helper"
require "flare/lifecycle"
require "flare/marker"
require "flare/filtering_span_processor"
require "flare/recording_batch_span_processor"

class FlareShutdownTest < Minitest::Test
  # Runs Lifecycle#shutdown on a throwaway object rather than the Flare
  # module, so no global state is touched. Loading lib/flare.rb here would
  # also skip the engine for integration tests that require Rails later.
  class FakeFlare
    include Flare::Lifecycle

    attr_reader :configuration
    attr_accessor :span_processor

    def initialize
      @configuration = Flare::Configuration.new
      @configuration.spans_enabled = false
    end

    def set(ivar, value) = instance_variable_set(ivar, value)
  end

  def setup
    @exporters = []
    @flare = FakeFlare.new
  end

  def teardown
    @exporters.each(&:release)
  end

  def test_metrics_get_the_budget_minus_the_trace_reservation
    metrics = FakeStoppable.new
    @flare.set(:@metric_flusher, metrics)

    @flare.shutdown(timeout: 5)

    assert_in_delta 4, metrics.timeout, 0.1
  end

  def test_rule_manager_stops_without_waiting
    rules = FakeStoppable.new
    @flare.set(:@rule_manager, rules)

    @flare.shutdown(timeout: 5)

    assert_equal 0, rules.timeout
  end

  def test_trace_shutdown_is_capped_when_trace_exporter_hangs
    @flare.set(:@trace_span_processor, hanging_trace_processor)

    elapsed = measure { @flare.shutdown(timeout: 5) }

    assert_operator elapsed, :<, Flare::Lifecycle::TRACE_SHUTDOWN_TIMEOUT + 0.5
  end

  def test_span_and_trace_processors_share_the_trace_budget
    @flare.configuration.spans_enabled = true
    @flare.span_processor = hanging_span_processor
    @flare.set(:@span_processor, @flare.span_processor)
    @flare.set(:@trace_span_processor, hanging_trace_processor)

    elapsed = measure { @flare.shutdown(timeout: 5) }

    # Both processors hang; separate budgets would take ~2s.
    assert_operator elapsed, :<, Flare::Lifecycle::TRACE_SHUTDOWN_TIMEOUT + 0.5
  end

  def test_slow_metrics_leave_traces_only_what_remains_of_the_total
    @flare.set(:@metric_flusher, FakeStoppable.new(sleep_for: 0.3))
    @flare.set(:@trace_span_processor, hanging_trace_processor)

    elapsed = measure { @flare.shutdown(timeout: 0.5) }

    assert_operator elapsed, :<, 1.0
  end

  def test_a_failing_step_does_not_skip_later_steps
    @flare.set(:@rule_manager, RaisingStoppable.new)
    metrics = FakeStoppable.new
    @flare.set(:@metric_flusher, metrics)

    _stdout, stderr = capture_io { @flare.shutdown(timeout: 5) }

    assert_includes stderr, "[Flare] rule manager shutdown error: boom"
    refute_nil metrics.timeout
  end

  private

  def hanging_trace_processor
    exporter = track(HangingExporter.new)
    processor = Flare::FilteringSpanProcessor.new(
      exporter: exporter,
      marker: Flare::Marker.new,
      flush_interval: 0.01,
      logger: Logger.new(IO::NULL)
    )
    # One trace stuck in an in-flight worker export, another still buffered.
    processor.on_finish(root_span("t1"))
    exporter.wait_until_started
    processor.on_finish(root_span("t2"))
    processor
  end

  def hanging_span_processor
    exporter = track(HangingExporter.new)
    processor = Flare::RecordingBatchSpanProcessor.new(
      exporter,
      schedule_delay: 10,
      logger: Logger.new(IO::NULL)
    )
    processor.on_finish(root_span("local"))
    processor
  end

  def track(exporter)
    @exporters << exporter
    exporter
  end

  def measure
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  def root_span(trace_id)
    MockSpan.new(trace_id, "#{trace_id}-root")
  end

  class FakeStoppable
    attr_reader :timeout

    def initialize(sleep_for: 0)
      @sleep_for = sleep_for
    end

    def stop(timeout:)
      @timeout = timeout
      sleep @sleep_for
    end
  end

  class RaisingStoppable
    def stop(timeout:) = raise("boom")
  end

  # Ignores the timeout it is given, like a stuck HTTP connection.
  class HangingExporter
    def initialize
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @started = false
      @released = false
    end

    def export(_spans, timeout: nil)
      @mutex.synchronize do
        @started = true
        @condition.broadcast
        @condition.wait(@mutex) until @released
      end
      OpenTelemetry::SDK::Trace::Export::SUCCESS
    end

    def wait_until_started
      @mutex.synchronize { @condition.wait(@mutex, 1) until @started }
    end

    def release
      @mutex.synchronize do
        @released = true
        @condition.broadcast
      end
    end

    def force_flush(timeout: nil) = OpenTelemetry::SDK::Trace::Export::SUCCESS
    def shutdown(timeout: nil) = OpenTelemetry::SDK::Trace::Export::SUCCESS
  end

  SpanData = Struct.new(:trace_id, :span_id, :parent_span_id, :kind, keyword_init: true)
  SpanContext = Struct.new(:trace_id, :span_id, :trace_flags)
  TraceFlags = Struct.new(:sampled?)

  class MockSpan
    def initialize(trace_id, span_id)
      @data = SpanData.new(trace_id: trace_id, span_id: span_id, parent_span_id: nil, kind: :server)
      @context = SpanContext.new(trace_id, span_id, TraceFlags.new(true))
    end

    def context = @context
    def to_span_data = @data
  end
end
