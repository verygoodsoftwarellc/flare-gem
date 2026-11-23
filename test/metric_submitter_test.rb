# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "stringio"
require "zlib"
require "flare/backoff_policy"
require "flare/metric_key"
require "flare/metric_submitter"

class MetricSubmitterTest < Minitest::Test
  def test_build_body_defaults_missing_slow_count_to_zero
    key = Flare::MetricKey.new(
      bucket: Time.utc(2026, 1, 1, 12, 30),
      namespace: "web",
      service: "rails",
      target: "HomeController#index",
      operation: "2xx"
    )

    submitter = metric_submitter
    body = submitter.send(:build_body, { key => { count: 1, sum_ms: 25, error_count: 0 } }, "req-1")
    payload = JSON.parse(Zlib::GzipReader.new(StringIO.new(body)).read)

    assert_equal 0, payload.fetch("metrics").first.fetch("slow_count")
  end

  def test_build_body_preserves_slow_count
    key = Flare::MetricKey.new(
      bucket: Time.utc(2026, 1, 1, 12, 30),
      namespace: "web",
      service: "rails",
      target: "HomeController#index",
      operation: "2xx"
    )

    submitter = metric_submitter
    body = submitter.send(:build_body, { key => { count: 3, sum_ms: 75, error_count: 0, slow_count: 2 } }, "req-1")
    payload = JSON.parse(Zlib::GzipReader.new(StringIO.new(body)).read)

    assert_equal 2, payload.fetch("metrics").first.fetch("slow_count")
  end

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
    submitter = TestSubmitter.new(backoff_policy: backoff, errors: [retriable_error])
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

  def test_retries_when_the_host_cannot_be_resolved_or_reached
    [SocketError, Errno::EHOSTUNREACH, Errno::ENETUNREACH].each do |error_class|
      submitter = TestSubmitter.new(backoff_policy: quick_backoff, errors: [error_class.new("first attempt")])

      count, error = submitter.submit(metrics)

      assert_nil error, error_class.name
      assert_equal 1, count, error_class.name
      assert_equal 2, submitter.timeouts.length, error_class.name
    end
  end

  def test_unexpected_errors_are_not_retried
    submitter = TestSubmitter.new(backoff_policy: quick_backoff, errors: [ArgumentError.new("bug")])

    count, error = submitter.submit(metrics)

    assert_equal 0, count
    assert_instance_of ArgumentError, error
    assert_equal 1, submitter.timeouts.length
  end

  private

  def metric_submitter
    Flare::MetricSubmitter.new(
      endpoint: "https://flare.example",
      api_key: "push_123",
      project: "app",
      environment: "test"
    )
  end

  def quick_backoff
    Flare::BackoffPolicy.new(min_timeout_ms: 1, max_timeout_ms: 1)
  end

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

    def initialize(backoff_policy: nil, errors: [], delay: 0)
      super(
        endpoint: "https://flare.example",
        api_key: "key",
        project: "test",
        environment: "test",
        backoff_policy: backoff_policy
      )
      @errors = errors.dup
      @delay = delay
      @timeouts = []
    end

    private

    def post(_body, _request_id, timeout: nil)
      @timeouts << timeout
      sleep @delay
      raise @errors.shift unless @errors.empty?

      [Response.new("202"), false]
    end
  end
end
