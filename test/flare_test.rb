# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

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

  # Runs in a subprocess: loading lib/flare.rb here would skip the engine for
  # the integration tests that require Rails later.
  def test_flush_metrics_drains_the_metric_flusher
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", <<~'RUBY', chdir: File.expand_path("..", __dir__))
      require "flare"

      puts Flare.flush_metrics

      submitter = Object.new
      def submitter.submit(drained) = [drained.size, nil]
      storage = Flare::MetricStorage.new
      key = Flare::MetricKey.new(bucket: Time.now.utc, namespace: "web", service: "rails", target: "UsersController", operation: "show")
      storage.increment(key, duration_ms: 100, error: false)
      Flare.metric_flusher = Flare::MetricFlusher.new(storage: storage, submitter: submitter)

      puts Flare.flush_metrics
      puts storage.empty?
    RUBY

    assert status.success?, stderr
    assert_equal %w[0 1 true], stdout.lines.map(&:strip)
  end
end
