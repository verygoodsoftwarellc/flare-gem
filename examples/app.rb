# frozen_string_literal: true

# Single-file Rails app for testing Flare
# Run with: bundle exec ruby examples/app.rb

require "bundler/setup"
require "rails"
require "action_controller/railtie"
require "active_job/railtie"
require "net/http"

# Load flare from local path
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "flare"

class App < Rails::Application
  config.root = __dir__
  config.eager_load = false
  config.consider_all_requests_local = true
  config.secret_key_base = "test-secret-key-base-for-development-only"
  config.hosts.clear
  config.log_level = :info
  config.active_job.queue_adapter = :inline
end

# A sample job that does various instrumented operations
class DataSyncJob < ActiveJob::Base
  queue_as :default

  def perform(user_id)
    # Simulate fetching user from database
    ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT * FROM users WHERE id = #{user_id}", name: "User Load") do
      sleep 0.008
    end

    # Simulate fetching user's orders
    ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT * FROM orders WHERE user_id = #{user_id} ORDER BY created_at DESC LIMIT 10", name: "Order Load") do
      sleep 0.015
    end

    # Check cache for computed stats
    ActiveSupport::Notifications.instrument("cache_read.active_support", key: "user:#{user_id}:stats", hit: false) do
      sleep 0.002
    end

    # Simulate computing stats
    ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT COUNT(*), SUM(total) FROM orders WHERE user_id = #{user_id}", name: "Order Stats") do
      sleep 0.012
    end

    # Write stats to cache
    ActiveSupport::Notifications.instrument("cache_write.active_support", key: "user:#{user_id}:stats") do
      sleep 0.003
    end

    # Simulate sending notification email
    ActiveSupport::Notifications.instrument("deliver.action_mailer", mailer: "UserMailer", action: "sync_complete", to: "user#{user_id}@example.com") do
      sleep 0.020
    end

    # Render a report template
    ActiveSupport::Notifications.instrument("render_template.action_view", identifier: "reports/sync_summary.html.erb") do
      sleep 0.005
    end

    Rails.logger.info "DataSyncJob completed for user #{user_id}"
  end
end

class HomeController < ActionController::Base
  def index
    # Simulate some instrumented activity
    ActiveSupport::Notifications.instrument("cache_read.active_support", key: "home:visited", hit: false) do
      sleep 0.001
    end

    render plain: <<~HTML, content_type: "text/html"
      <!DOCTYPE html>
      <html>
      <head><title>Flare Demo</title></head>
      <body style="font-family: system-ui; max-width: 600px; margin: 40px auto; padding: 0 20px;">
        <h1>Flare Demo</h1>
        <p>A minimal Rails app to test Flare instrumentation.</p>
        <h3>Requests</h3>
        <ul>
          <li><a href="/api">API endpoint (simulates SQL + cache + view)</a></li>
          <li><a href="/slow">Slow endpoint (500ms delay)</a></li>
          <li><a href="/http">HTTP request endpoint (makes outgoing HTTP call)</a></li>
          <li><a href="/error">Error endpoint (reports exception)</a></li>
        </ul>
        <h3>Jobs</h3>
        <form action="/enqueue_job" method="post" style="margin: 0;">
          <input type="hidden" name="authenticity_token" value="#{form_authenticity_token}">
          <button type="submit" style="padding: 8px 16px; cursor: pointer;">
            Enqueue DataSyncJob (SQL + cache + mail + view)
          </button>
        </form>
        <hr>
        <p><strong><a href="/flare">Open Flare Dashboard</a></strong></p>
      </body>
      </html>
    HTML
  end

  def api
    # Simulate SQL query
    ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT * FROM users WHERE id = 1", name: "User Load") do
      ActiveSupport::Notifications.instrument("foo.bar", baz: "wick") do
        sleep 0.005
      end
    end

    # Simulate cache read
    ActiveSupport::Notifications.instrument("cache_read.active_support", key: "user:1", hit: true) do
      sleep 0.001
    end

    # Simulate view render
    ActiveSupport::Notifications.instrument("render_template.action_view", identifier: "users/show.html.erb") do
      sleep 0.010
    end

    render json: { status: "ok", user: { id: 1, name: "Demo User" } }
  end

  def slow
    ActiveSupport::Notifications.instrument("slow_operation.app", operation: "heavy_computation") do
      sleep 0.5
    end
    render plain: "Done after 500ms"
  end

  def http_request
    # Make an outgoing HTTP request
    uri = URI("https://httpbin.org/json")
    response = Net::HTTP.get_response(uri)
    render json: { status: response.code, body: JSON.parse(response.body) }
  rescue => e
    render json: { error: e.message }, status: 500
  end

  def error
    # Report an error using the Rails error reporter so it gets captured as a clue
    begin
      raise StandardError, "Intentional error for testing Flare exceptions"
    rescue => e
      Rails.error.report(e, handled: true, severity: :error, context: { endpoint: "error", user_id: 42 })
      render plain: "Error was reported: #{e.message}", status: 500
    end
  end

  def enqueue_job
    user_id = rand(1..100)
    DataSyncJob.perform_later(user_id)
    redirect_to "/", notice: "DataSyncJob enqueued for user #{user_id}"
  end
end

Rails.application.initialize!

# Draw routes after initialization so the engine is fully loaded
Rails.application.routes.draw do
  root "home#index"
  get "/api", to: "home#api"
  get "/slow", to: "home#slow"
  get "/http", to: "home#http_request"
  get "/error", to: "home#error"
  post "/enqueue_job", to: "home#enqueue_job"
end

if __FILE__ == $0
  require "rack/handler/puma"
  port = ENV.fetch("PORT", 9999).to_i
  puts "Starting Flare demo at http://localhost:#{port}"
  puts "Dashboard available at http://localhost:#{port}/flare"
  Rack::Handler::Puma.run(Rails.application, Port: port, Host: "0.0.0.0", Verbose: false)
end
