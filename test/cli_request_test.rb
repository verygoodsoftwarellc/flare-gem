# frozen_string_literal: true

require "minitest/autorun"
require_relative "cli_spans_support"

class CLIRequestTest < Minitest::Test
  include CLISpansSupport
  STARTED = Time.at(1_800_000_000, 123_456, :usec)

  def test_prints_the_timeline_in_order_with_query_sources
    in_app do |dir|
      seed_request(dir)

      out, err, status = flare(dir, "request", "t1")

      assert status.success?, err
      lines = out.lines.map(&:chomp)
      assert_equal "GET /posts/1  500  12.3ms  PostsController#show", lines[0]
      assert_equal "Started #{STARTED.iso8601(3)}  1 queries", lines[1]
      assert_equal "Exception: ActiveRecord::RecordNotFound: Couldn't find Post", lines[2]
      assert_match %r{\A\s+1\.0ms\s+0\.5ms  sql\.active_record: SELECT \* FROM posts WHERE id = \?  app/models/post\.rb:7\z}, lines[5]
      assert_match %r{\A\s+2\.0ms\s+0\.1ms  sql\.active_record: BEGIN\z}, lines[6]
      assert_match %r{\A\s+3\.0ms\s+4\.0ms  render_template\.action_view: posts/show\.html\.erb\z}, lines[7]
      assert_equal 8, lines.size
    end
  end

  def test_prints_json
    in_app do |dir|
      seed_request(dir)

      out, err, status = flare(dir, "request", "--json", "t1")

      assert status.success?, err
      request = JSON.parse(out)
      assert_equal "t1", request["trace_id"]
      assert_equal "GET", request["method"]
      assert_equal "/posts/1", request["path"]
      assert_equal 500, request["status"]
      assert_equal 12.3, request["duration_ms"]
      assert_equal 1, request["queries"], "transaction statements aren't queries, same as flare requests"
      assert_equal "PostsController", request["controller"]
      assert_equal "show", request["action"]
      assert_equal STARTED.iso8601(3), request["started_at"]
      assert_equal "ActiveRecord::RecordNotFound", request["exceptions"].first["type"]
      assert_equal "app/models/post.rb:7\napp/controllers/posts_controller.rb:4", request["exceptions"].first["stacktrace"]
      assert_equal({
        "name" => "sql.active_record", "offset_ms" => 1.0, "duration_ms" => 0.5,
        "detail" => "SELECT * FROM posts WHERE id = ?", "source" => "app/models/post.rb:7",
      }, request["spans"].first)
      assert_equal 3, request["spans"].size, "the request itself isn't in its own timeline"
    end
  end

  def test_reads_newer_otel_property_names
    in_app do |dir|
      db = create_database(dir)
      insert_at_offset(db, trace: "t1", name: "GET", parent: ROOT_PARENT, offset: 0, ms: 1,
        properties: { "http.request.method" => "POST", "url.path" => "/posts", "http.response.status_code" => 201 })
      db.close

      out, err, status = flare(dir, "request", "t1")

      assert status.success?, err
      assert_equal "POST /posts  201  1.0ms", out.lines.first.chomp
      assert_equal 2, out.lines.size, "no timeline header without child spans"
    end
  end

  def test_names_a_trace_that_is_not_an_http_request
    in_app do |dir|
      db = create_database(dir)
      insert_at_offset(db, trace: "t1", name: "CleanupJob process", parent: ROOT_PARENT, offset: 0, ms: 1, properties: {})
      db.close

      out, err, status = flare(dir, "request", "t1")

      assert status.success?, err
      assert_equal "CleanupJob process  1.0ms", out.lines.first.chomp
    end
  end

  def test_points_to_flare_requests_for_an_unknown_trace
    in_app do |dir|
      seed_request(dir)

      out, err, status = flare(dir, "request", "nope")

      refute status.success?
      assert_empty out
      assert_equal "No request with trace id nope. Run `flare requests` to list recent ones.\n", err
    end
  end

  def test_requires_exactly_one_trace_id
    in_app do |dir|
      [[], %w[t1 t2]].each do |ids|
        out, err, status = flare(dir, "request", *ids)

        refute status.success?, "#{ids.inspect} should fail"
        assert_empty out
        assert_includes err, "Usage: flare request <trace_id>"
      end
    end
  end

  def test_fails_with_a_hint_and_creates_nothing_when_the_database_is_missing
    in_app do |dir|
      out, err, status = flare(dir, "request", "t1")

      refute status.success?
      assert_empty out
      assert_includes err, "No Flare spans database at #{File.join(dir, "db", "flare.sqlite3")}"
      refute File.exist?(File.join(dir, "db")), "should not create the database"
    end
  end

  def test_reads_the_database_given_with_db_and_leaves_it_untouched
    in_app do |dir|
      seed_request(dir, "tmp/custom.sqlite3")
      path = File.join(dir, "tmp/custom.sqlite3")
      before = File.binread(path)

      out, err, status = flare(dir, "request", "t1", "--db", "tmp/custom.sqlite3")

      assert status.success?, err
      assert_includes out, "GET /posts/1"
      assert_equal before, File.binread(path)
    end
  end

  def test_explains_a_database_without_flare_tables
    in_app do |dir|
      path = File.join(dir, "app.sqlite3")
      SQLite3::Database.new(path).close

      out, err, status = flare(dir, "request", "t1", "--db", path)

      refute status.success?
      assert_empty out
      assert_includes err, "Could not read #{path}: no such table: flare_spans"
    end
  end

  private

  def seed_request(dir, relative = "db/flare.sqlite3")
    db = create_database(dir, relative)
    root = insert_at_offset(db, trace: "t1", name: "GET /posts/:id", parent: ROOT_PARENT, offset: 0, ms: 12.34,
      properties: { "http.method" => "GET", "http.target" => "/posts/1", "http.status_code" => 500, "code.namespace" => "PostsController", "code.function" => "show" })
    insert_exception(db, root, "ActiveRecord::RecordNotFound", "Couldn't find Post", "app/models/post.rb:7\napp/controllers/posts_controller.rb:4")
    # Inserted out of order: the timeline sorts by start time.
    insert_at_offset(db, trace: "t1", name: "render_template.action_view", parent: "root", offset: 3, ms: 4,
      properties: { "identifier" => "/srv/app/app/views/posts/show.html.erb" })
    insert_at_offset(db, trace: "t1", name: "sql.active_record", parent: "root", offset: 1, ms: 0.5,
      properties: { "db.statement" => "SELECT *\n  FROM posts WHERE id = ?", "code.filepath" => "app/models/post.rb", "code.lineno" => 7 })
    insert_at_offset(db, trace: "t1", name: "sql.active_record", parent: "root", offset: 2, ms: 0.1, properties: { "db.statement" => "BEGIN" })
    insert_at_offset(db, trace: "other", name: "sql.active_record", parent: "root", offset: 0, ms: 1, properties: { "db.statement" => "SELECT 'other trace'" })
    db.close
  end

  def insert_at_offset(db, trace:, name:, parent:, offset:, ms:, properties:)
    insert_span(db, trace: trace, name: name, kind: "server", parent: parent, ns: (ms * 1_000_000).to_i,
      at: STARTED + offset / 1000r, properties: properties)
  end

  def insert_exception(db, span_id, type, message, stacktrace)
    stamp = STARTED.iso8601(6)
    db.execute("INSERT INTO flare_events (span_id, name, created_at, updated_at) VALUES (?, 'exception', ?, ?)", [span_id, stamp, stamp])
    insert_properties(db, "Flare::Event", db.last_insert_row_id,
      { "exception.type" => type, "exception.message" => message, "exception.stacktrace" => stacktrace }, stamp)
  end
end
