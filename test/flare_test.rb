# frozen_string_literal: true

require "test_helper"

class TestFlare < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Flare::VERSION
  end

  def test_configuration_defaults
    config = Flare::Configuration.new

    assert_equal true, config.enabled
    assert_equal 24, config.retention_hours
    assert_equal 10_000, config.max_spans
  end

  def test_tracing_submission_requires_tracing_endpoint_and_key
    config = Flare::Configuration.new
    config.tracing_enabled = true
    config.url = "https://flare.example"
    config.key = nil

    refute config.tracing_submission_configured?

    config.key = "push_123"
    assert config.tracing_submission_configured?

    config.tracing_enabled = false
    refute config.tracing_submission_configured?
  end
end
