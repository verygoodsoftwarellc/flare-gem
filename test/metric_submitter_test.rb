# frozen_string_literal: true

require_relative "test_helper"
require "flare/backoff_policy"
require "flare/metric_key"
require "flare/metric_submitter"

class MetricSubmitterTest < Minitest::Test
  def test_propagates_remaining_timeout_to_submission
    submitter = TestSubmitter.new

    count, error = submitter.submit(metrics, timeout: 0.5)

    assert_equal 1, count
    assert_nil error
    assert_operator submitter.timeouts.first, :>, 0
    assert_operator submitter.timeouts.first, :<=, 0.5
  end

  def test_retry_backoff_returns_deadline_error_without_sleeping_past_budget
    backoff = Flare::BackoffPolicy.new(min_timeout_ms: 1_000, max_timeout_ms: 1_000)
    submitter = TestSubmitter.new(backoff_policy: backoff, error: retriable_error)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    count, error = submitter.submit(metrics, timeout: 0.02)

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    assert_equal 0, count
    assert_instance_of Flare::MetricSubmitter::DeadlineExceeded, error
    assert_operator elapsed, :<, 0.2
    assert_equal 1, submitter.timeouts.length
  end

  def test_successful_response_after_deadline_is_reported_as_timeout
    submitter = TestSubmitter.new(delay: 0.05)

    count, error = submitter.submit(metrics, timeout: 0.01)

    assert_equal 0, count
    assert_instance_of Flare::MetricSubmitter::DeadlineExceeded, error
  end

  private

  def metrics
    key = Flare::MetricKey.new(
      bucket: Time.now.utc,
      namespace: "web",
      service: "rails",
      target: "UsersController#index",
      operation: "2xx"
    )
    { key => { count: 1, sum_ms: 10, error_count: 0 } }
  end

  def retriable_error
    Flare::MetricSubmitter::SubmissionError.new("retry", request_id: "request")
  end

  Response = Struct.new(:code)

  class TestSubmitter < Flare::MetricSubmitter
    attr_reader :timeouts

    def initialize(backoff_policy: nil, error: nil, delay: 0)
      super(
        endpoint: "https://flare.example",
        api_key: "key",
        project: "test",
        environment: "test",
        backoff_policy: backoff_policy
      )
      @error = error
      @delay = delay
      @timeouts = []
    end

    private

    def post(_body, _request_id, timeout: nil)
      @timeouts << timeout
      sleep @delay
      raise @error if @error

      [Response.new("202"), false]
    end
  end
end
