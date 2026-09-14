# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"

class ConfiguredTraceLifecycleTest < Minitest::Test
  def test_configured_key_with_no_rules_keeps_trace_local_only
    result = run_configured_process("unmatched")

    assert_equal ["GET /users", "sql.active_record"], result.fetch("stored").sort
    assert_equal 0, result.fetch("remote_puts")
    assert_equal 0, result.fetch("remote_posts")
  end

  def test_configured_key_with_matching_rule_keeps_trace_local_and_submits_remote
    result = run_configured_process("matching")

    assert_equal ["GET /users", "sql.active_record"], result.fetch("stored").sort
    assert_equal 1, result.fetch("remote_puts")
    assert_equal 1, result.fetch("remote_posts")
  end

  def test_without_key_preserves_local_always_on_behavior
    result = run_configured_process("no_key")

    assert_equal ["GET /users", "sql.active_record"], result.fetch("stored").sort
    assert_equal 0, result.fetch("remote_puts")
    assert_equal 0, result.fetch("remote_posts")
  end

  private

  def run_configured_process(mode)
    directory = Dir.mktmpdir
    database_path = File.join(directory, "flare.sqlite3")
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-Ilib",
      "-e",
      configured_process_script,
      database_path,
      mode,
      chdir: File.expand_path("..", __dir__)
    )
    assert status.success?, stderr
    JSON.parse(stdout.lines.last)
  ensure
    FileUtils.remove_entry(directory) if directory && File.exist?(directory)
  end

  def configured_process_script
    <<~'RUBY'
      database_path, mode = ARGV
      key = mode == "no_key" ? nil : "push_test"
      ENV["FLARE_KEY"] = key
      require "json"
      require "sqlite3"
      require "active_support"
      require "active_support/notifications"
      require "flare"

      Flare.configure do |config|
        config.database_path = database_path
        config.spans_enabled = true
        config.metrics_enabled = false
        config.tracing_enabled = true
        config.url = "https://flare.example"
        config.key = key
      end
      Flare.configure_opentelemetry

      transport = Class.new do
        attr_reader :puts, :posts

        def initialize
          @puts = 0
          @posts = 0
        end

        def put(_url, _body, _headers, timeout: nil)
          @puts += 1
          Flare::HttpTransport::Response.new(code: "200", body: "")
        end

        def post(_url, _body, _headers, timeout: nil)
          @posts += 1
          Flare::HttpTransport::Response.new(code: "202", body: "")
        end
      end.new

      if key
        Flare.setup_tracing_components
        rules = if mode == "matching"
          [{ "id" => 7, "match_attributes" => { "code.namespace" => "UsersController" }, "rate" => 1.0 }]
        else
          []
        end
        Flare.sampler.update_rules(rules)
        Flare.upload_url_pool.replace([
          {
            upload_id: "u1",
            key: "incoming/test/u1.json.gz",
            put_url: "https://r2.example/u1",
            expires_at: Time.now + 60
          }
        ])
        Flare.instance_variable_get(:@trace_exporter).instance_variable_set(:@transport, transport)
      end

      tracer = OpenTelemetry.tracer_provider.tracer("configured-lifecycle-test")
      tracer.in_span("GET /users", kind: :server, attributes: { "code.namespace" => "UsersController" }) do
        tracer.in_span("sql.active_record", attributes: { "db.system" => "sqlite" }) { nil }
      end

      result = Flare.force_flush(timeout: 1)
      abort "flush failed: #{result}" unless result == OpenTelemetry::SDK::Trace::Export::SUCCESS

      database = SQLite3::Database.new(database_path)
      stored = database.execute("SELECT name FROM flare_spans").flatten
      database.close
      puts JSON.generate(stored: stored, remote_puts: transport.puts, remote_posts: transport.posts)
    RUBY
  end
end
