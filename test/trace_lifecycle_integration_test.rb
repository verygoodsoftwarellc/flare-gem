# frozen_string_literal: true

require_relative "test_helper"
require "rails"
require "flare"

class TraceLifecycleIntegrationTest < Minitest::Test
  SUCCESS = OpenTelemetry::SDK::Trace::Export::SUCCESS

  def setup
    @directory = Dir.mktmpdir
    @database_path = File.join(@directory, "flare.sqlite3")
    @previous_database_path = Flare.configuration.database_path
    @previous_spans_enabled = Flare.configuration.spans_enabled
    @previous_tracing_enabled = Flare.configuration.tracing_enabled
    @previous_url = Flare.configuration.url
    @previous_key = Flare.configuration.key
    Flare.configuration.database_path = @database_path
    Flare.configuration.spans_enabled = true
    Flare.configuration.tracing_enabled = true
    Flare.configuration.url = "https://flare.example"
    Flare.configuration.key = "push_test"
    @processors = []
  end

  def teardown
    @processors.reverse_each { |processor| processor.shutdown(timeout: 1) }
    Flare.configuration.database_path = @previous_database_path
    Flare.configuration.spans_enabled = @previous_spans_enabled
    Flare.configuration.tracing_enabled = @previous_tracing_enabled
    Flare.configuration.url = @previous_url
    Flare.configuration.key = @previous_key
    FileUtils.remove_entry(@directory)
  end

  def test_record_only_request_and_child_are_local_but_not_remote_with_key_and_no_rules
    assert Flare.configuration.tracing_submission_configured?
    provider, remote = configured_provider(rules: [])
    finish_request_trace(provider, attributes: { "code.namespace" => "UsersController" })

    assert_equal SUCCESS, provider.force_flush(timeout: 1)
    assert_equal ["GET /users", "sql.active_record"], stored_span_names.sort
    assert_empty remote.spans
  end

  def test_matching_rule_stores_locally_and_submits_remotely
    assert Flare.configuration.tracing_submission_configured?
    provider, remote = configured_provider(
      rules: [{ "id" => 7, "match_attributes" => { "code.namespace" => "UsersController" }, "rate" => 1.0 }]
    )
    finish_request_trace(provider, attributes: { "code.namespace" => "UsersController" })

    assert_equal SUCCESS, provider.force_flush(timeout: 1)
    assert_equal ["GET /users", "sql.active_record"], stored_span_names.sort
    assert_equal ["GET /users", "sql.active_record"], remote.spans.map(&:name).sort
    assert remote.spans.all? { |span| span.trace_flags.sampled? }
  end

  def test_failures_only_rule_submits_only_requests_that_fail_the_slo
    provider, remote = configured_provider(
      rules: [{ "id" => 7, "match_attributes" => { "code.namespace" => "UsersController" }, "rate" => 1.0,
                "capture" => "slo_failures" }],
      slo_rules: [{ "namespace" => "web", "threshold_ms" => 20 }]
    )
    attributes = { "code.namespace" => "UsersController", "code.function" => "index" }

    finish_request_trace(provider, attributes: attributes.merge("http.status_code" => 200))
    finish_request_trace(provider, attributes: attributes.merge("http.status_code" => 200)) { sleep 0.05 }
    finish_request_trace(provider, attributes: attributes.merge("http.status_code" => 500))

    assert_equal SUCCESS, provider.force_flush(timeout: 1)
    assert_equal 6, stored_span_names.length, "local storage still keeps every request"

    blobs = remote.spans.group_by(&:trace_id).map { |trace_id, spans| Flare::TraceBlob.build(trace_id: trace_id, spans: spans).to_h }
    assert_equal %w[error slow], blobs.map { |blob| blob["capture_reason"] }.sort
    assert blobs.all? { |blob| blob["trace_rule_id"] == 7 && blob["spans"].length == 2 }
  end

# Regression: ISSUE-001 — a job run inline (a nested consumer span) ended a
# sampled failures-only trace early and uploaded part of a passing request
# Found by /qa on 2026-11-23
def test_failures_only_rule_judges_a_request_that_runs_a_job_inline_at_the_request
  provider, remote = configured_provider(
    rules: [{ "id" => 7, "match_attributes" => { "code.namespace" => "UsersController" }, "rate" => 1.0,
              "capture" => "slo_failures" }],
    slo_rules: [{ "namespace" => "web", "threshold_ms" => 20 }]
  )
  attributes = { "code.namespace" => "UsersController", "code.function" => "index", "http.status_code" => 200 }

  finish_request_trace(provider, attributes: attributes) { run_job_inline(provider) }
  finish_request_trace(provider, attributes: attributes) { run_job_inline(provider); sleep 0.05 }

  assert_equal SUCCESS, provider.force_flush(timeout: 1)
  blobs = remote.spans.group_by(&:trace_id).map { |trace_id, spans| Flare::TraceBlob.build(trace_id: trace_id, spans: spans).to_h }
  assert_equal 1, blobs.length, "only the slow request is uploaded"
  assert_equal "slow", blobs.first["capture_reason"]
  assert_equal ["GET /users", "ReportJob perform", "sql.active_record"], blobs.first["spans"].map { |s| s["name"] }.sort
end

  def test_without_key_local_always_on_behavior_is_unchanged
    Flare.configuration.key = nil
    refute Flare.configuration.tracing_submission_configured?
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    add_local_processor(provider)
    finish_request_trace(provider, attributes: { "code.namespace" => "UsersController" })

    assert_equal SUCCESS, provider.force_flush(timeout: 1)
    assert_equal ["GET /users", "sql.active_record"], stored_span_names.sort
  end

  private

  def configured_provider(rules:, slo_rules: [])
    sampler = Flare::Sampler.new
    sampler.update_rules(rules)
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new(
      sampler: OpenTelemetry::SDK::Trace::Samplers.parent_based(
        root: sampler,
        remote_parent_sampled: Flare::ALWAYS_RECORD_ONLY,
        remote_parent_not_sampled: Flare::ALWAYS_RECORD_ONLY,
        local_parent_not_sampled: Flare::ALWAYS_RECORD_ONLY
      )
    )
    add_local_processor(provider)

    remote = RecordingTraceExporter.new
    slo_manager = Flare::SloManager.new
    slo_manager.update(slo_rules)
    processor = Flare::FilteringSpanProcessor.new(
      exporter: remote,
      marker: Flare::Marker.new,
      sampler: sampler,
      slo_check: Flare::MetricSpanProcessor.new(storage: nil, slo_manager: slo_manager),
      flush_interval: 60,
      logger: Logger.new(IO::NULL)
    )
    provider.add_span_processor(processor)
    @processors << processor
    [provider, remote]
  end

  def add_local_processor(provider)
    processor = Flare::RecordingBatchSpanProcessor.new(
      Flare::SQLiteExporter.new(@database_path),
      schedule_delay: 60_000,
      logger: Logger.new(IO::NULL)
    )
    provider.add_span_processor(processor)
    @processors << processor
  end

  def finish_request_trace(provider, attributes:)
    tracer = provider.tracer("lifecycle-test")
    tracer.in_span("GET /users", kind: :server, attributes: attributes) do
      tracer.in_span("sql.active_record", attributes: { "db.system" => "sqlite" }) { nil }
      yield if block_given?
    end
  end

def run_job_inline(provider)
  provider.tracer("lifecycle-test").in_span("ReportJob perform", kind: :consumer) { nil }
end

  def stored_span_names
    database = SQLite3::Database.new(@database_path)
    database.execute("SELECT name FROM flare_spans").flatten
  ensure
    database&.close
  end

  class RecordingTraceExporter < Flare::TraceExporter
    attr_reader :spans

    def initialize
      @spans = []
    end

    def export(spans, timeout: nil)
      @spans.concat(spans)
      SUCCESS
    end

    def force_flush(timeout: nil) = SUCCESS
    def shutdown(timeout: nil) = SUCCESS
  end
end
