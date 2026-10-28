# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "sqlite3"
require "time"
require "tmpdir"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "flare/storage"
require "flare/storage/sqlite"

# Runs exe/flare in a subprocess, the way `bundle exec flare requests` runs in
# an app, against a spans database laid out like SQLiteExporter writes it.
class CLIRequestsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  ROOT_PARENT = "0000000000000000"

  def test_lists_recent_requests_newest_first_with_query_counts
    in_app do |dir|
      db = create_database(dir)
      started = Time.at(Time.now.to_i - 60, 123_456, :usec)
      insert_request(db, trace: "t1", path: "/posts", status: 200, controller: "PostsController", action: "index", ms: 12.34, at: started,
        queries: ["SELECT * FROM posts", "BEGIN", "SELECT * FROM users WHERE id = 1", "COMMIT"])
      insert_request(db, trace: "t2", path: "/posts/1", status: 404, controller: "PostsController", action: "show", ms: 3, at: Time.now,
        queries: [])
      db.close

      out, err, status = flare(dir, "requests", "--json")

      assert status.success?, err
      requests = JSON.parse(out)
      assert_equal %w[t2 t1], requests.map { |r| r["trace_id"] }, "newest first"
      assert_equal({
        "trace_id" => "t1", "method" => "GET", "path" => "/posts", "status" => 200, "duration_ms" => 12.3,
        "queries" => 2, "controller" => "PostsController", "action" => "index",
        "started_at" => started.iso8601(3),
      }, requests.last)
      assert_equal 0, requests.first["queries"]

      out, err, status = flare(dir, "requests", "--last", "1")

      assert status.success?, err
      lines = out.lines
      assert_equal 1, lines.size
      assert_match %r{GET\s+404\s+3\.0ms\s+0 queries\s+/posts/1\s+PostsController#show\s+t2}, lines.first
    end
  end

  def test_says_so_when_nothing_is_recorded
    in_app do |dir|
      create_database(dir).close

      out, err, status = flare(dir, "requests")

      assert status.success?, err
      assert_equal "No requests recorded yet.\n", out
    end
  end

  def test_fails_with_a_hint_and_creates_nothing_when_the_database_is_missing
    in_app do |dir|
      out, err, status = flare(dir, "requests")

      refute status.success?
      assert_empty out
      assert_includes err, "No Flare spans database at #{File.join(dir, "db", "flare.sqlite3")}"
      refute File.exist?(File.join(dir, "db")), "should not create the database"
    end
  end

  def test_reads_the_database_given_with_db
    in_app do |dir|
      db = create_database(dir, "tmp/custom.sqlite3")
      insert_request(db, trace: "t1", path: "/", status: 200, controller: "HomeController", action: "show", ms: 1, at: Time.now)
      db.close

      out, err, status = flare(dir, "requests", "--json", "--db", "tmp/custom.sqlite3")

      assert status.success?, err
      assert_equal ["t1"], JSON.parse(out).map { |r| r["trace_id"] }
    end
  end

  def test_rejects_bad_options
    in_app do |dir|
      _, err, status = flare(dir, "requests", "--last", "lots")

      refute status.success?
      assert_includes err, "invalid argument: --last lots"
    end
  end

  def test_rejects_a_last_below_one
    in_app do |dir|
      create_database(dir).close

      %w[0 -1].each do |n|
        out, err, status = flare(dir, "requests", "--last", n)

        refute status.success?, "--last #{n} should fail"
        assert_empty out
        assert_equal "invalid argument: --last #{n} (must be at least 1)\n", err
      end
    end
  end

  def test_explains_a_file_that_is_not_a_spans_database
    in_app do |dir|
      FileUtils.mkdir_p(File.join(dir, "db"))
      File.write(File.join(dir, "db", "flare.sqlite3"), "not a database")

      out, err, status = flare(dir, "requests")

      refute status.success?
      assert_empty out
      assert_match(/\ACould not read .*flare\.sqlite3: file is not a database/, err)
      refute_includes err, ".rb:", "no backtrace"
    end
  end

  private

  def in_app
    Dir.mktmpdir { |dir| yield File.realpath(dir) }
  end

  def flare(dir, *args)
    Open3.capture3(RbConfig.ruby, "-I", File.join(ROOT, "lib"), File.join(ROOT, "exe", "flare"), *args, chdir: dir)
  end

  def create_database(dir, relative = "db/flare.sqlite3")
    path = File.join(dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    Flare::Storage::SQLite.new(path).send(:setup_database)
    SQLite3::Database.new(path)
  end

  def insert_request(db, trace:, path:, status:, controller:, action:, ms:, at:, queries: [])
    root = insert_span(db, trace: trace, name: "GET #{path}", kind: "server", parent: ROOT_PARENT, ns: (ms * 1_000_000).to_i, at: at,
      properties: { "http.method" => "GET", "http.target" => path, "http.status_code" => status, "code.namespace" => controller, "code.function" => action })
    queries.each do |sql|
      insert_span(db, trace: trace, name: "sql.active_record", kind: "internal", parent: root.to_s, ns: 1000, at: at,
        properties: { "db.statement" => sql })
    end
  end

  def insert_span(db, trace:, name:, kind:, parent:, ns:, at:, properties:)
    stamp = at.iso8601(6)
    start = (at.to_r * 1_000_000_000).to_i
    db.execute(<<~SQL, [name, kind, "s#{rand(1 << 32)}", trace, parent, start, start + ns, stamp, stamp])
      INSERT INTO flare_spans (name, kind, span_id, trace_id, parent_span_id, start_timestamp, end_timestamp, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL
    id = db.last_insert_row_id
    properties.each do |key, value|
      db.execute("INSERT INTO flare_properties (key, value, value_type, owner_type, owner_id, created_at, updated_at) VALUES (?, ?, ?, 'Flare::Span', ?, ?, ?)",
        [key, JSON.generate(value), value.is_a?(Integer) ? 1 : 0, id, stamp, stamp])
    end
    id
  end
end
