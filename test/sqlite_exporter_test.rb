# frozen_string_literal: true

require_relative "test_helper"
require "flare/sqlite_exporter"
require "flare/storage/sqlite"

class SQLiteExporterTest < Minitest::Test
  def setup
    @tmp_dir = Dir.mktmpdir
    @db_path = File.join(@tmp_dir, "test.sqlite3")
    @exporter = Flare::SQLiteExporter.new(@db_path)
  end

  def teardown
    FileUtils.rm_rf(@tmp_dir)
    # Clear thread-local connection
    Thread.current[:flare_sqlite_db] = nil
  end

  def test_creates_database_on_first_export
    refute File.exist?(@db_path)
    @exporter.export([mock_span_data])
    assert File.exist?(@db_path)
  end

  def test_creates_spans_table_on_first_export
    @exporter.export([mock_span_data])
    db = SQLite3::Database.new(@db_path, results_as_hash: true)
    tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'").map { |r| r["name"] }
    assert_includes tables, "flare_spans"
  end

  def test_creates_events_table_on_first_export
    @exporter.export([mock_span_data])
    db = SQLite3::Database.new(@db_path, results_as_hash: true)
    tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'").map { |r| r["name"] }
    assert_includes tables, "flare_events"
  end

  def test_creates_properties_table_on_first_export
    @exporter.export([mock_span_data])
    db = SQLite3::Database.new(@db_path, results_as_hash: true)
    tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'").map { |r| r["name"] }
    assert_includes tables, "flare_properties"
  end

  def test_export_returns_success
    span_data = mock_span_data
    result = @exporter.export([span_data])
    assert_equal Flare::SQLiteExporter::SUCCESS, result
  end

  def test_export_creates_span_record
    span_data = mock_span_data(
      name: "GET /users",
      kind: :server,
      span_id: "abc123",
      trace_id: "trace456"
    )

    @exporter.export([span_data])

    db = SQLite3::Database.new(@db_path, results_as_hash: true)
    spans = db.execute("SELECT * FROM flare_spans")

    assert_equal 1, spans.size
    assert_equal "GET /users", spans.first["name"]
    assert_equal "server", spans.first["kind"]
    assert_equal "abc123", spans.first["span_id"]
    assert_equal "trace456", spans.first["trace_id"]
  end

  def test_export_creates_properties_for_span
    span_data = mock_span_data(
      name: "GET /users",
      attributes: {
        "http.method" => "GET",
        "http.status_code" => 200,
        "http.target" => "/users"
      }
    )

    @exporter.export([span_data])

    db = SQLite3::Database.new(@db_path, results_as_hash: true)
    properties = db.execute("SELECT * FROM flare_properties WHERE owner_type = 'Flare::Span'")

    assert_equal 3, properties.size

    method_prop = properties.find { |p| p["key"] == "http.method" }
    assert_equal '"GET"', method_prop["value"]
    assert_equal 0, method_prop["value_type"] # string

    status_prop = properties.find { |p| p["key"] == "http.status_code" }
    assert_equal "200", status_prop["value"]
    assert_equal 1, status_prop["value_type"] # integer
  end

  def test_export_creates_events
    span_event = mock_span_event(
      name: "exception",
      attributes: {
        "exception.type" => "RuntimeError",
        "exception.message" => "Something went wrong"
      }
    )

    span_data = mock_span_data(
      name: "GET /boom",
      events: [span_event]
    )

    @exporter.export([span_data])

    db = SQLite3::Database.new(@db_path, results_as_hash: true)
    events = db.execute("SELECT * FROM flare_events")

    assert_equal 1, events.size
    assert_equal "exception", events.first["name"]

    # Check event properties
    event_props = db.execute("SELECT * FROM flare_properties WHERE owner_type = 'Flare::Event'")
    assert_equal 2, event_props.size

    type_prop = event_props.find { |p| p["key"] == "exception.type" }
    assert_equal '"RuntimeError"', type_prop["value"]
  end

  def test_export_ignores_flare_spans
    span_data = mock_span_data(name: "Flare::SomeInternal")

    @exporter.export([span_data])

    db = SQLite3::Database.new(@db_path, results_as_hash: true)
    spans = db.execute("SELECT * FROM flare_spans")

    assert_equal 0, spans.size
  end

  def test_export_handles_nil_attributes
    span_data = mock_span_data(
      name: "GET /users",
      attributes: nil
    )

    result = @exporter.export([span_data])
    assert_equal Flare::SQLiteExporter::SUCCESS, result
  end

  def test_export_handles_nil_events
    span_data = mock_span_data(
      name: "GET /users",
      events: nil
    )

    result = @exporter.export([span_data])
    assert_equal Flare::SQLiteExporter::SUCCESS, result
  end

  def test_export_skips_nil_attribute_values
    span_data = mock_span_data(
      name: "GET /users",
      attributes: {
        "http.method" => "GET",
        "some.nil.value" => nil
      }
    )

    @exporter.export([span_data])

    db = SQLite3::Database.new(@db_path, results_as_hash: true)
    properties = db.execute("SELECT * FROM flare_properties WHERE owner_type = 'Flare::Span'")

    assert_equal 1, properties.size
    assert_equal "http.method", properties.first["key"]
  end

  def test_force_flush_returns_success
    result = @exporter.force_flush
    assert_equal Flare::SQLiteExporter::SUCCESS, result
  end

  def test_shutdown_returns_success
    result = @exporter.shutdown
    assert_equal Flare::SQLiteExporter::SUCCESS, result
  end

  def test_determines_value_types_correctly
    span_data = mock_span_data(
      name: "test",
      attributes: {
        "string_val" => "hello",
        "int_val" => 42,
        "float_val" => 3.14,
        "bool_true" => true,
        "bool_false" => false,
        "array_val" => [1, 2, 3]
      }
    )

    @exporter.export([span_data])

    db = SQLite3::Database.new(@db_path, results_as_hash: true)
    properties = db.execute("SELECT key, value_type FROM flare_properties ORDER BY key")

    prop_types = properties.each_with_object({}) { |p, h| h[p["key"]] = p["value_type"] }

    assert_equal 4, prop_types["array_val"]    # array
    assert_equal 3, prop_types["bool_false"]   # boolean
    assert_equal 3, prop_types["bool_true"]    # boolean
    assert_equal 2, prop_types["float_val"]    # float
    assert_equal 1, prop_types["int_val"]      # integer
    assert_equal 0, prop_types["string_val"]   # string
  end

  def test_export_multiple_spans
    span1 = mock_span_data(name: "GET /users", trace_id: "trace1")
    span2 = mock_span_data(name: "POST /users", trace_id: "trace1")

    @exporter.export([span1, span2])

    db = SQLite3::Database.new(@db_path, results_as_hash: true)
    spans = db.execute("SELECT * FROM flare_spans ORDER BY name")

    assert_equal 2, spans.size
    assert_equal "GET /users", spans[0]["name"]
    assert_equal "POST /users", spans[1]["name"]
  end

  def test_creates_parent_directory_if_missing
    nested_path = File.join(@tmp_dir, "nested", "dir", "test.sqlite3")
    exporter = Flare::SQLiteExporter.new(nested_path)
    exporter.export([mock_span_data])

    assert File.exist?(nested_path)
  end

  private

  def mock_span_data(
    name: "test span",
    kind: :internal,
    span_id: "span123",
    trace_id: "trace123",
    parent_span_id: "0000000000000000",
    start_timestamp: Time.now.to_i * 1_000_000_000,
    end_timestamp: (Time.now.to_i + 1) * 1_000_000_000,
    attributes: {},
    events: []
  )
    MockSpanData.new(
      name: name,
      kind: kind,
      hex_span_id: span_id,
      hex_trace_id: trace_id,
      hex_parent_span_id: parent_span_id,
      start_timestamp: start_timestamp,
      end_timestamp: end_timestamp,
      attributes: attributes,
      events: events,
      total_recorded_links: 0,
      total_recorded_events: events&.size || 0,
      total_recorded_attributes: attributes&.size || 0
    )
  end

  def mock_span_event(name: "event", timestamp: nil, attributes: {})
    MockSpanEvent.new(
      name: name,
      timestamp: timestamp || Time.now.to_i * 1_000_000_000,
      attributes: attributes
    )
  end

  MockSpanData = Struct.new(
    :name,
    :kind,
    :hex_span_id,
    :hex_trace_id,
    :hex_parent_span_id,
    :start_timestamp,
    :end_timestamp,
    :attributes,
    :events,
    :total_recorded_links,
    :total_recorded_events,
    :total_recorded_attributes,
    keyword_init: true
  )

  MockSpanEvent = Struct.new(
    :name,
    :timestamp,
    :attributes,
    keyword_init: true
  )
end
