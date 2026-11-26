# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"

# Runs a real Rails app in a subprocess so Rails.error, the Rack/ActionPack/
# ActiveJob instrumentation and the span fallback all see the same errors.
class ErrorTrackingRailsTest < Minitest::Test
  SCRIPT = <<~'RUBY'
    require "json"
    require "logger"
    require "rails"
    require "action_controller/railtie"
    require "active_job/railtie"
    require "concurrent/executor/immediate_executor"
    require "flare"

    class BoomController < ActionController::Base
      def show
        raise ArgumentError, "bad id 42"
      end

      def handled
        Rails.error.handle { raise KeyError, "missing" }
        head :ok
      end

      def missing
        raise ActionController::RoutingError, "nope"
      end
    end

    class BoomJob < ActiveJob::Base
      def perform
        raise IOError, "disk"
      end
    end

    class App < Rails::Application
      config.eager_load = false
      config.hosts.clear
      config.secret_key_base = "x" * 64
      config.logger = Logger.new(IO::NULL)
      config.active_job.queue_adapter = :inline
      config.action_dispatch.show_exceptions = :all
      config.paths["config/routes.rb"] = []
    end
    Rails.application.initialize!
    Rails.application.routes.draw do
      get "/boom" => "boom#show"
      get "/handled" => "boom#handled"
      get "/missing" => "boom#missing"
    end

    tracker = Flare::ErrorTracker.new(executor: Concurrent::ImmediateExecutor.new)
    Flare::ErrorTracker.current = tracker
    OpenTelemetry::SDK::Trace::Span.prepend(Flare::ErrorTracker::SpanExceptionCapture)
    storage = Flare::MetricStorage.new
    OpenTelemetry.tracer_provider.add_span_processor(Flare.metric_span_processor(storage, error_tracker: tracker))
    Flare.subscribe_to_error_reporter

    request = ->(path) { Rack::MockRequest.new(Rails.application).get(path) }

    # Off until /api/rules says otherwise.
    request.("/boom")
    tracker.record(storage)
    off = storage.drain.keys.count { |k| k.namespace == "error" }

    tracker.apply_rules({ "error_tracking" => true })
    statuses = [request.("/boom").status, request.("/boom").status, request.("/handled").status, request.("/missing").status]
    begin
      ActiveJob::Base.execute(BoomJob.new.serialize)
    rescue IOError
    end

    tracker.record(storage)
    rows = storage.drain.select { |k, _| k.namespace == "error" }.map do |k, v|
      { service: k.service, operation: k.operation, count: v[:count], unhandled: v[:error_count] }
    end
    puts JSON.generate(off: off, statuses: statuses, rows: rows.sort_by { |r| r[:service] }, waiting: tracker.waiting_count)
  RUBY

  def test_rails_errors_count_once_each
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", SCRIPT, chdir: File.expand_path("..", __dir__))
    assert status.success?, stderr
    result = JSON.parse(stdout.lines.last)

    assert_equal 0, result["off"], "nothing counted while the gate is off"
    assert_equal [500, 500, 200, 404], result["statuses"]
    assert_equal [
      { "service" => "ArgumentError", "operation" => "BoomController#show", "count" => 2, "unhandled" => 2 },
      { "service" => "IOError", "operation" => "BoomJob", "count" => 1, "unhandled" => 1 },
      { "service" => "KeyError", "operation" => "BoomController#handled", "count" => 1, "unhandled" => 0 }
    ], result["rows"]
    assert_equal 3, result["waiting"]
  end
end
