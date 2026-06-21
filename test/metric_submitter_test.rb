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

  private

  def metric_submitter
    Flare::MetricSubmitter.new(
      endpoint: "https://flare.example",
      api_key: "push_123",
      project: "app",
      environment: "test"
    )
  end
end
