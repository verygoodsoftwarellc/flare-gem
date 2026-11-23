# frozen_string_literal: true

require_relative "test_helper"
require "flare/filtering_span_processor"
require "flare/marker"
require "flare/recording_batch_span_processor"
require "flare/sampler"
require "flare/sqlite_exporter"

class LocalRemoteSamplingTest < Minitest::Test
  SUCCESS = OpenTelemetry::SDK::Trace::Export::SUCCESS
  SPAN_NAMES = [
    "sql.active_record",
    "render_template.action_view",
    "cache_read.active_support",
    "GET /users"
  ].freeze

  def setup
    unless Flare.respond_to?(:log)
      Flare.define_singleton_method(:log) { |_message| }
      @remove_flare_log = true
    end

    @tmp_dir = Dir.mktmpdir
    @database_path = File.join(@tmp_dir, "flare.sqlite3")
  end

  def teardown
    @provider&.shutdown(timeout: 1)
    FileUtils.rm_rf(@tmp_dir)
    Thread.current[:flare_sqlite_db] = nil
    Flare.singleton_class.remove_method(:log) if @remove_flare_log
  end

  def test_key_with_no_matching_rules_records_entire_trace_locally_but_does_not_upload
    pipeline = build_pipeline(key: "push_123", rules: [])

    root = record_request(pipeline[:tracer])
    @provider.force_flush(timeout: 1)

    refute root.context.trace_flags.sampled?
    assert_equal SPAN_NAMES, local_span_names
    assert_empty pipeline[:remote_exporter].spans
  end

  def test_matching_rule_records_entire_trace_locally_and_uploads_it
    pipeline = build_pipeline(
      key: "push_123",
      rules: [
        {
          "id" => 7,
          "match_attributes" => {"code.namespace" => "UsersController"},
          "rate" => 1.0
        }
      ]
    )

    root = record_request(pipeline[:tracer])
    @provider.force_flush(timeout: 1)

    assert root.context.trace_flags.sampled?
    assert_equal SPAN_NAMES, local_span_names
    assert_equal SPAN_NAMES, pipeline[:remote_exporter].spans.map(&:name)
  end

  def test_without_key_keeps_existing_always_on_local_recording_behavior
    pipeline = build_pipeline(key: nil, rules: [])

    root = record_request(pipeline[:tracer])
    @provider.force_flush(timeout: 1)

    assert root.context.trace_flags.sampled?
    assert_equal SPAN_NAMES, local_span_names
    assert_nil pipeline[:remote_exporter]
  end

  private

  def build_pipeline(key:, rules:)
    remote_exporter = nil
    sampler = OpenTelemetry::SDK::Trace::Samplers::ALWAYS_ON

    if key
      flare_sampler = Flare::Sampler.new
      flare_sampler.update_rules(rules)
      sampler = OpenTelemetry::SDK::Trace::Samplers.parent_based(
        root: flare_sampler,
        remote_parent_sampled: Flare::ALWAYS_RECORD_ONLY,
        remote_parent_not_sampled: Flare::ALWAYS_RECORD_ONLY,
        local_parent_not_sampled: Flare::ALWAYS_RECORD_ONLY
      )
    end

    @provider = OpenTelemetry::SDK::Trace::TracerProvider.new(sampler: sampler)
    local_processor = Flare::RecordingBatchSpanProcessor.new(
      Flare::SQLiteExporter.new(@database_path),
      max_queue_size: 100,
      max_export_batch_size: 100,
      schedule_delay: 60_000
    )
    @provider.add_span_processor(local_processor)

    if key
      remote_exporter = RecordingExporter.new
      remote_processor = Flare::FilteringSpanProcessor.new(
        exporter: remote_exporter,
        marker: Flare::Marker.new,
        max_queue: 100,
        flush_interval: 60,
        logger: Logger.new(IO::NULL)
      )
      @provider.add_span_processor(remote_processor)
    end

    {tracer: @provider.tracer("flare-test"), remote_exporter: remote_exporter}
  end

  def record_request(tracer)
    root = tracer.start_span(
      "GET /users",
      kind: :server,
      attributes: {
        "code.namespace" => "UsersController",
        "code.function" => "index"
      }
    )
    parent_context = OpenTelemetry::Trace.context_with_span(root)

    %w[sql.active_record render_template.action_view cache_read.active_support].each do |name|
      child = tracer.start_span(name, with_parent: parent_context)
      child.finish
    end
    root.finish
    root
  end

  def local_span_names
    database = SQLite3::Database.new(@database_path, results_as_hash: true)
    database.execute("SELECT name FROM flare_spans ORDER BY id").map { |row| row["name"] }
  ensure
    database&.close
  end

  class RecordingExporter
    attr_reader :spans

    def initialize
      @spans = []
    end

    def export(spans, timeout: nil)
      @spans.concat(spans)
      SUCCESS
    end

    def shutdown(timeout: nil)
      SUCCESS
    end
  end
end
