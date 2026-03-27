# frozen_string_literal: true

# Quick smoke test: submit metrics from the Flare client to a running flare-web instance.
#
# Usage:
#   bundle exec ruby examples/submit_metrics_test.rb
#
# Prerequisites:
#   - flare-web running locally (e.g. on Conductor port 55030)
#
# You can override the defaults with env vars:
#   FLARE_TEST_ENDPOINT  - base URL of flare-web (default: http://localhost:55030)
#   FLARE_TEST_API_KEY   - bearer token (default: the seed token)
#   FLARE_TEST_PROJECT   - project key (default: flipper-cloud)
#   FLARE_TEST_ENV       - environment key (default: production)

require "bundler/setup"
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "flare"
require "flare/backoff_policy"
require "flare/metric_submitter"

base = ENV.fetch("FLARE_TEST_ENDPOINT", "http://localhost:55030")
project = ENV.fetch("FLARE_TEST_PROJECT", "flipper-cloud")
environment = ENV.fetch("FLARE_TEST_ENV", "production")
api_key = ENV.fetch("FLARE_TEST_API_KEY", "sRQyUpiVhUedfJPDoC2tSGK9")

# Build the full endpoint with query params
base = base.chomp("/")
endpoint = "#{base}/api/metrics?project=#{project}&environment=#{environment}"

puts "=== Flare MetricSubmitter smoke test ==="
puts "Endpoint: #{endpoint}"
puts

# Build a handful of realistic-looking metric keys + values
now = Time.now.utc
bucket = Time.utc(now.year, now.month, now.day, now.hour, now.min) # truncate to minute

drained = {
  Flare::MetricKey.new(
    bucket: bucket,
    namespace: "web",
    service: "rails",
    target: "HomeController",
    operation: "index"
  ) => { count: 12, sum_ms: 345, error_count: 0 },

  Flare::MetricKey.new(
    bucket: bucket,
    namespace: "web",
    service: "rails",
    target: "UsersController",
    operation: "show"
  ) => { count: 8, sum_ms: 620, error_count: 1 },

  Flare::MetricKey.new(
    bucket: bucket,
    namespace: "db",
    service: "postgres",
    target: "users",
    operation: "SELECT"
  ) => { count: 20, sum_ms: 88, error_count: 0 },

  Flare::MetricKey.new(
    bucket: bucket,
    namespace: "job",
    service: "rails",
    target: "DataSyncJob",
    operation: "perform"
  ) => { count: 3, sum_ms: 1500, error_count: 0 },

  Flare::MetricKey.new(
    bucket: bucket,
    namespace: "http",
    service: "api.stripe.com",
    target: "/v1/charges",
    operation: "POST"
  ) => { count: 5, sum_ms: 430, error_count: 2 }
}

submitter = Flare::MetricSubmitter.new(
  endpoint: endpoint,
  api_key: api_key,
  open_timeout: 5,
  read_timeout: 10
)

puts "Submitting #{drained.size} metric keys (bucket: #{bucket.strftime('%Y-%m-%dT%H:%M:%SZ')})..."

count, error = submitter.submit(drained)

if error
  puts "FAILED: #{error.class} - #{error.message}"
  if error.respond_to?(:response_code)
    puts "  HTTP #{error.response_code}: #{error.response_body}"
  end
  exit 1
else
  puts "SUCCESS: #{count} metrics accepted by the server"
  puts
  puts "Check flare-web to see the metrics appear under:"
  puts "  Project: flipper-cloud"
  puts "  Environment: production"
end
