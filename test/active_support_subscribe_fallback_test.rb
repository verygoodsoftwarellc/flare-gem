# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

class ActiveSupportSubscribeFallbackTest < Minitest::Test
  # Flare requires an internal OTel file for ActiveSupport.subscribe. If a
  # future release moves it, boot should warn and keep tracing, not raise.
  def test_boots_and_traces_when_the_internal_span_subscriber_file_is_missing
    stdout, stderr, status = Dir.mktmpdir do |directory|
      Open3.capture3(
        { "OTEL_RUBY_INSTRUMENTATION_ACTIVESUPPORT_ENABLED" => "false" },
        RbConfig.ruby, "-Ilib", "-e", script, File.join(directory, "flare.sqlite3"),
        chdir: File.expand_path("..", __dir__)
      )
    end

    assert status.success?, stderr
    assert_includes stderr, "[Flare] OpenTelemetry::Instrumentation::ActiveSupport.subscribe not found"
    assert_equal "GET /users", stdout.lines.last.strip
  end

  private

  def script
    <<~'RUBY'
      Object.prepend(Module.new do
        def require(path)
          raise LoadError, "cannot load such file -- #{path}" if path == "opentelemetry/instrumentation/active_support/span_subscriber"
          super
        end
      end)

      require "sqlite3"
      require "active_support"
      require "active_support/notifications"
      require "flare"

      Flare.configure do |config|
        config.database_path = ARGV.fetch(0)
        config.spans_enabled = true
        config.metrics_enabled = false
      end
      Flare.configure_opentelemetry

      OpenTelemetry.tracer_provider.tracer("fallback-test").in_span("GET /users", kind: :server) { nil }
      abort "flush failed" unless Flare.force_flush == OpenTelemetry::SDK::Trace::Export::SUCCESS
      puts SQLite3::Database.new(ARGV.fetch(0)).execute("SELECT name FROM flare_spans").flatten.join(",")
    RUBY
  end
end
