# frozen_string_literal: true

require_relative "test_helper"
require "flare/backoff_policy"
require "flare/metric_key"
require "flare/slo_manager"
require "flare/metric_submitter"

class MetricSubmitterTest < Minitest::Test
  FakeResponse = Struct.new(:code, :body)

  def setup
    @slo_manager = Flare::SloManager.new
    @submitter = Flare::MetricSubmitter.new(
      endpoint: "https://flare.example",
      api_key: "key_abc",
      project: "demo-app",
      environment: "production",
      slo_manager: @slo_manager
    )
  end

  def test_submit_applies_slo_from_response
    response = FakeResponse.new("200", JSON.generate(
      "slo" => {
        "defaults" => { "web" => 1000, "job" => 60000 },
        "operations" => [
          { "namespace" => "web", "service" => "rails",
            "target" => "FeedsController#serve_feed", "threshold_ms" => 250 }
        ]
      }
    ))

    submitted, error = stub_post(response) { @submitter.submit(drained) }

    assert_equal 1, submitted
    assert_nil error
    assert_equal({ "web" => 1000, "job" => 60000 }, @slo_manager.defaults)
    assert_equal 250, @slo_manager.threshold_for(namespace: "web", service: "rails", target: "FeedsController#serve_feed")
  end

  def test_submit_without_slo_section_is_noop
    @slo_manager.update(defaults: { "web" => 500 })
    response = FakeResponse.new("200", JSON.generate("ok" => true))

    stub_post(response) { @submitter.submit(drained) }

    # Existing config is left untouched when no slo section is present.
    assert_equal({ "web" => 500 }, @slo_manager.defaults)
  end

  def test_submit_tolerates_unparsable_body
    @slo_manager.update(defaults: { "web" => 500 })
    response = FakeResponse.new("200", "not json")

    submitted, error = stub_post(response) { @submitter.submit(drained) }

    assert_equal 1, submitted
    assert_nil error
    assert_equal({ "web" => 500 }, @slo_manager.defaults)
  end

  def test_submit_tolerates_empty_body
    response = FakeResponse.new("200", "")

    submitted, error = stub_post(response) { @submitter.submit(drained) }

    assert_equal 1, submitted
    assert_nil error
    assert_equal({}, @slo_manager.defaults)
  end

  def test_no_slo_manager_does_not_raise
    submitter = Flare::MetricSubmitter.new(endpoint: "https://flare.example", api_key: "key_abc")
    response = FakeResponse.new("200", JSON.generate("slo" => { "defaults" => { "web" => 1000 } }))

    submitted, error = submitter.stub(:post, [response, false]) { submitter.submit(drained) }

    assert_equal 1, submitted
    assert_nil error
  end

  private

  def stub_post(response, &block)
    @submitter.stub(:post, [response, false], &block)
  end

  def drained
    key = Flare::MetricKey.new(
      bucket: Time.now.utc,
      namespace: "web",
      service: "rails",
      target: "UsersController#show",
      operation: "2xx"
    )
    { key => { count: 1, sum_ms: 100, error_count: 0, slow_count: 0 } }
  end
end
