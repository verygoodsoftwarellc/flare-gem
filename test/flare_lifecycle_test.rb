# frozen_string_literal: true

require_relative "test_helper"
require "flare/lifecycle"

class FlareLifecycleTest < Minitest::Test
  SUCCESS = OpenTelemetry::SDK::Trace::Export::SUCCESS
  FAILURE = OpenTelemetry::SDK::Trace::Export::FAILURE

  def teardown
    Flare.instance_variable_set(:@metric_flusher, nil)
  end

  def test_force_flush_shares_one_timeout_budget_between_traces_and_metrics
    provider = FakeProvider.new(delay: 0.02)
    metrics = FakeMetricFlusher.new
    Flare.instance_variable_set(:@metric_flusher, metrics)

    result = Flare.stub(:tracer_provider_for_flush, provider) do
      Flare.force_flush(timeout: 0.5)
    end

    assert_equal SUCCESS, result
    assert_operator provider.timeout, :<=, 0.5
    assert_operator metrics.timeout, :<, provider.timeout
    assert_operator metrics.timeout, :>, 0
  end

  def test_force_flush_keeps_telemetry_exceptions_nonfatal
    provider = FakeProvider.new(error: RuntimeError.new("boom"))

    result = nil
    _stdout, stderr = capture_io do
      result = Flare.stub(:tracer_provider_for_flush, provider) do
        Flare.force_flush(timeout: 0.1)
      end
    end

    assert_equal FAILURE, result
    assert_includes stderr, "Telemetry flush error: boom"
  end

  class FakeProvider
    attr_reader :timeout

    def initialize(delay: 0, error: nil)
      @delay = delay
      @error = error
    end

    def force_flush(timeout: nil)
      @timeout = timeout
      sleep @delay
      raise @error if @error

      SUCCESS
    end
  end

  class FakeMetricFlusher
    attr_reader :timeout

    def force_flush(timeout: nil)
      @timeout = timeout
      SUCCESS
    end
  end
end
