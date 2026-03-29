# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"

ENV["RAILS_ENV"] = "test"

require "rails"
require "action_controller/railtie"
require "action_view/railtie"

TMP_DIR = Dir.mktmpdir

require_relative "../lib/flare"

Flare.configure do |c|
  c.database_path = File.join(TMP_DIR, "flare_test.sqlite3")
end

class TestApp < Rails::Application
  config.eager_load = false
  config.hosts.clear
  config.secret_key_base = "test_secret_key_base_for_flare_tests"
  config.active_support.deprecation = :silence

  # Avoid conflict with engine auto-mount
  config.paths["config/routes.rb"] = []
  config.action_controller.allow_forgery_protection = false
end

Rails.application.initialize!

class IntegrationTest < Minitest::Test
  include Rack::Test::Methods

  def app
    Rails.application
  end

  def setup
    @db_path = Flare.configuration.database_path

    Flare.reset_storage!
    Flare.storage.clear_all
  end

  def teardown
    Flare.storage.clear_all
  end

  def create_request_span(trace_id:, name: "GET /users", method: "GET", status: 200, controller: "UsersController", action: "index")
    db = SQLite3::Database.new(@db_path, results_as_hash: true)
    now = Time.now.iso8601(6)
    start_ts = Time.now.to_i * 1_000_000_000
    end_ts = start_ts + 100_000_000 # 100ms

    db.execute(<<~SQL, [name, "server", "span_#{trace_id}", trace_id, Flare::MISSING_PARENT_ID, start_ts, end_ts, 0, 0, 0, now, now])
      INSERT INTO flare_spans (name, kind, span_id, trace_id, parent_span_id, start_timestamp, end_timestamp, total_recorded_properties, total_recorded_events, total_recorded_links, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL

    span_id = db.last_insert_row_id

    db.execute(<<~SQL, ["http.request.method", "\"#{method}\"", 0, "Flare::Span", span_id, now, now])
      INSERT INTO flare_properties (key, value, value_type, owner_type, owner_id, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    SQL

    db.execute(<<~SQL, ["http.response.status_code", status.to_s, 1, "Flare::Span", span_id, now, now])
      INSERT INTO flare_properties (key, value, value_type, owner_type, owner_id, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    SQL

    db.execute(<<~SQL, ["url.path", "\"/users\"", 0, "Flare::Span", span_id, now, now])
      INSERT INTO flare_properties (key, value, value_type, owner_type, owner_id, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    SQL

    db.execute(<<~SQL, ["code.namespace", "\"#{controller}\"", 0, "Flare::Span", span_id, now, now])
      INSERT INTO flare_properties (key, value, value_type, owner_type, owner_id, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    SQL

    db.execute(<<~SQL, ["code.function", "\"#{action}\"", 0, "Flare::Span", span_id, now, now])
      INSERT INTO flare_properties (key, value, value_type, owner_type, owner_id, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    SQL

    span_id
  end

  def create_job_span(trace_id:, name: "MyJob process", job_class: "MyJob", queue: "default")
    db = SQLite3::Database.new(@db_path, results_as_hash: true)
    now = Time.now.iso8601(6)
    start_ts = Time.now.to_i * 1_000_000_000
    end_ts = start_ts + 50_000_000 # 50ms

    db.execute(<<~SQL, [name, "consumer", "span_#{trace_id}", trace_id, Flare::MISSING_PARENT_ID, start_ts, end_ts, 0, 0, 0, now, now])
      INSERT INTO flare_spans (name, kind, span_id, trace_id, parent_span_id, start_timestamp, end_timestamp, total_recorded_properties, total_recorded_events, total_recorded_links, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL

    span_id = db.last_insert_row_id

    db.execute(<<~SQL, ["code.namespace", "\"#{job_class}\"", 0, "Flare::Span", span_id, now, now])
      INSERT INTO flare_properties (key, value, value_type, owner_type, owner_id, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    SQL

    db.execute(<<~SQL, ["messaging.destination", "\"#{queue}\"", 0, "Flare::Span", span_id, now, now])
      INSERT INTO flare_properties (key, value, value_type, owner_type, owner_id, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    SQL

    span_id
  end

  def create_query_span(trace_id:, parent_span_id:, name: "sql.active_record", statement: "SELECT * FROM users")
    db = SQLite3::Database.new(@db_path, results_as_hash: true)
    now = Time.now.iso8601(6)
    start_ts = Time.now.to_i * 1_000_000_000
    end_ts = start_ts + 5_000_000 # 5ms

    db.execute(<<~SQL, [name, "internal", "child_span_#{rand(10000)}", trace_id, parent_span_id, start_ts, end_ts, 0, 0, 0, now, now])
      INSERT INTO flare_spans (name, kind, span_id, trace_id, parent_span_id, start_timestamp, end_timestamp, total_recorded_properties, total_recorded_events, total_recorded_links, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL

    span_id = db.last_insert_row_id

    db.execute(<<~SQL, ["db.statement", "\"#{statement}\"", 0, "Flare::Span", span_id, now, now])
      INSERT INTO flare_properties (key, value, value_type, owner_type, owner_id, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    SQL

    span_id
  end

  def create_exception_span(trace_id:, parent_span_id:, exception_type: "RuntimeError", exception_message: "Something went wrong")
    db = SQLite3::Database.new(@db_path, results_as_hash: true)
    now = Time.now.iso8601(6)
    start_ts = Time.now.to_i * 1_000_000_000
    end_ts = start_ts + 1_000_000 # 1ms

    db.execute(<<~SQL, ["exception", "internal", "exc_span_#{rand(10000)}", trace_id, parent_span_id, start_ts, end_ts, 0, 1, 0, now, now])
      INSERT INTO flare_spans (name, kind, span_id, trace_id, parent_span_id, start_timestamp, end_timestamp, total_recorded_properties, total_recorded_events, total_recorded_links, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL

    span_id = db.last_insert_row_id

    db.execute(<<~SQL, [span_id, "exception", now, now])
      INSERT INTO flare_events (span_id, name, created_at, updated_at)
      VALUES (?, ?, ?, ?)
    SQL

    event_id = db.last_insert_row_id

    db.execute(<<~SQL, ["exception.type", "\"#{exception_type}\"", 0, "Flare::Event", event_id, now, now])
      INSERT INTO flare_properties (key, value, value_type, owner_type, owner_id, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    SQL

    db.execute(<<~SQL, ["exception.message", "\"#{exception_message}\"", 0, "Flare::Event", event_id, now, now])
      INSERT INTO flare_properties (key, value, value_type, owner_type, owner_id, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    SQL

    span_id
  end

  def test_requests_index_empty
    get "/flare/requests"

    assert last_response.ok?, "Expected 200, got #{last_response.status}"
    assert_includes last_response.body, "Requests"
  end

  def test_requests_index_with_data
    create_request_span(trace_id: "trace_001", name: "GET /users", method: "GET", status: 200)
    create_request_span(trace_id: "trace_002", name: "POST /users", method: "POST", status: 201)

    get "/flare/requests"

    assert last_response.ok?
    assert_includes last_response.body, "UsersController"
    assert_includes last_response.body, "badge-get"
    assert_includes last_response.body, "badge-post"
  end

  def test_requests_index_filters_by_status
    create_request_span(trace_id: "trace_001", status: 200)
    create_request_span(trace_id: "trace_002", status: 500)

    get "/flare/requests", { status: "2xx" }

    assert last_response.ok?
    assert_includes last_response.body, "200"
  end

  def test_requests_index_filters_by_method
    create_request_span(trace_id: "trace_001", method: "GET")
    create_request_span(trace_id: "trace_002", method: "POST")

    get "/flare/requests", { method: "GET" }

    assert last_response.ok?
  end

  def test_requests_show
    create_request_span(trace_id: "trace_show_001", name: "GET /users", controller: "UsersController", action: "index")

    get "/flare/requests/trace_show_001"

    assert last_response.ok?
    assert_includes last_response.body, "GET /users"
  end

  def test_requests_show_not_found
    get "/flare/requests/nonexistent_trace"

    assert last_response.redirect?
    follow_redirect!
    assert last_response.ok?
  end

  def test_requests_show_with_child_spans
    create_request_span(trace_id: "trace_with_children", name: "GET /users")

    db = SQLite3::Database.new(@db_path, results_as_hash: true)
    row = db.execute("SELECT span_id FROM flare_spans WHERE trace_id = ?", ["trace_with_children"]).first
    parent_span_id = row["span_id"]

    create_query_span(trace_id: "trace_with_children", parent_span_id: parent_span_id, statement: "SELECT * FROM users")

    get "/flare/requests/trace_with_children"

    assert last_response.ok?
    assert_includes last_response.body, "GET /users"
  end

  def test_jobs_index_empty
    get "/flare/jobs"

    assert last_response.ok?
    assert_includes last_response.body, "Jobs"
  end

  def test_jobs_index_with_data
    create_job_span(trace_id: "job_trace_001", job_class: "SendEmailJob", queue: "mailers")
    create_job_span(trace_id: "job_trace_002", job_class: "ProcessOrderJob", queue: "default")

    get "/flare/jobs"

    assert last_response.ok?
    assert_includes last_response.body, "SendEmailJob"
    assert_includes last_response.body, "ProcessOrderJob"
  end

  def test_jobs_show
    create_job_span(trace_id: "job_show_trace", job_class: "MyTestJob", queue: "critical")

    get "/flare/jobs/job_show_trace"

    assert last_response.ok?
    assert_includes last_response.body, "MyTestJob"
  end

  def test_jobs_show_not_found
    get "/flare/jobs/nonexistent_job_trace"

    assert last_response.redirect?
    follow_redirect!
    assert last_response.ok?
  end

  def test_queries_index_empty
    get "/flare/spans/queries"

    assert last_response.ok?
    assert_includes last_response.body, "Queries"
  end

  def test_queries_index_with_data
    span_id = create_request_span(trace_id: "query_trace_001")
    db = SQLite3::Database.new(@db_path, results_as_hash: true)
    row = db.execute("SELECT span_id FROM flare_spans WHERE id = ?", [span_id]).first
    parent_span_id = row["span_id"]

    create_query_span(trace_id: "query_trace_001", parent_span_id: parent_span_id, statement: "SELECT * FROM posts WHERE id = 1")

    get "/flare/spans/queries"

    assert last_response.ok?
    assert_includes last_response.body, "SELECT * FROM posts WHERE id = 1"
  end

  def test_exceptions_index_empty
    get "/flare/spans/exceptions"

    assert last_response.ok?
    assert_includes last_response.body, "Exceptions"
  end

  def test_exceptions_index_with_data
    span_id = create_request_span(trace_id: "exc_trace_001")
    db = SQLite3::Database.new(@db_path, results_as_hash: true)
    row = db.execute("SELECT span_id FROM flare_spans WHERE id = ?", [span_id]).first
    parent_span_id = row["span_id"]

    create_exception_span(trace_id: "exc_trace_001", parent_span_id: parent_span_id, exception_type: "ActiveRecord::RecordNotFound", exception_message: "Couldn't find User")

    get "/flare/spans/exceptions"

    assert last_response.ok?
  end

  def test_cache_index
    get "/flare/spans/cache"

    assert last_response.ok?
    assert_includes last_response.body, "Cache"
  end

  def test_views_index
    get "/flare/spans/views"

    assert last_response.ok?
    assert_includes last_response.body, "Views"
  end

  def test_http_index
    get "/flare/spans/http"

    assert last_response.ok?
    assert_includes last_response.body, "HTTP"
  end

  def test_mail_index
    get "/flare/spans/mail"

    assert last_response.ok?
    assert_includes last_response.body, "Mail"
  end

  def test_root_redirects_to_requests
    get "/flare"

    assert last_response.ok?
    assert_includes last_response.body, "Requests"
  end

  def test_clear_data
    create_request_span(trace_id: "to_be_cleared")

    delete "/flare/clear"

    assert last_response.redirect?, "Expected redirect after clear, got status #{last_response.status}"

    follow_redirect!

    requests = Flare.storage.list_requests
    assert_equal 0, requests.size
  end

  def test_requests_pagination
    55.times do |i|
      create_request_span(trace_id: "paginated_trace_#{i.to_s.rjust(3, '0')}")
    end

    get "/flare/requests"

    assert last_response.ok?
    assert_includes last_response.body, "Next"
  end
end
