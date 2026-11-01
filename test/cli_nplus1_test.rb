# frozen_string_literal: true

require "minitest/autorun"
require_relative "cli_spans_support"

class CLINplus1Test < Minitest::Test
  include CLISpansSupport

  COMMENTS = 'SELECT "comments".* FROM "comments" WHERE "comments"."post_id" = ?'

  def test_reports_repeated_queries_with_the_code_that_ran_them
    in_app do |dir|
      db = create_database(dir)
      root = insert_root(db, "t1", "/posts")
      3.times { insert_query(db, "t1", root, COMMENTS, ms: 1.5, file: "app/views/posts/index.html.erb", line: 3) }
      insert_query(db, "t1", root, COMMENTS, ms: 0.5, file: "app/models/post.rb", line: 9)
      insert_query(db, "t1", root, 'SELECT "posts".* FROM "posts"', ms: 2)
      db.close

      out, err, status = flare(dir, "nplus1")

      assert status.success?, err
      lines = out.lines.map(&:chomp)
      assert_equal "GET /posts  200  10.0ms  PostsController#index  t1", lines[0]
      assert_equal "   4x     5.0ms  #{COMMENTS}", lines[1]
      assert_equal "      3x  app/views/posts/index.html.erb:3", lines[2]
      assert_equal "      1x  app/models/post.rb:9", lines[3]
      assert_equal 4, lines.size, "a query that ran once isn't reported"
    end
  end

  def test_treats_one_query_with_different_values_as_the_same_query
    in_app do |dir|
      db = create_database(dir)
      root = insert_root(db, "t1", "/search")
      [
        "SELECT * FROM users WHERE id = 1 AND name = 'it''s' /* action:index */",
        "SELECT *\n  FROM users WHERE id = 22 AND name = 'bob'",
      ].each { |statement| insert_query(db, "t1", root, statement) }
      ["SELECT * FROM posts WHERE id IN (1, 2)", "SELECT * FROM posts WHERE id IN ($1, $2, $3)", "SELECT * FROM posts WHERE id IN (?)"]
        .each { |statement| insert_query(db, "t1", root, statement) }
      # Digits in an identifier are part of the query, not a value.
      ["SELECT * FROM table1", "SELECT * FROM table2"].each { |statement| insert_query(db, "t1", root, statement) }
      db.close

      out, err, status = flare(dir, "nplus1", "--json")

      assert status.success?, err
      statements = JSON.parse(out).first["repeated"].to_h { |query| [query["statement"], query["count"]] }
      assert_equal({
        "SELECT * FROM posts WHERE id IN (?)" => 3,
        "SELECT * FROM users WHERE id = ? AND name = ?" => 2,
      }, statements)
    end
  end

  def test_ignores_what_active_record_repeats_by_design
    in_app do |dir|
      db = create_database(dir)
      root = insert_root(db, "t1", "/posts")
      2.times do
        insert_query(db, "t1", root, "BEGIN immediate TRANSACTION", name: "TRANSACTION")
        insert_query(db, "t1", root, "PRAGMA table_xinfo(\"posts\")", name: "SCHEMA")
      end
      db.close

      out, err, status = flare(dir, "nplus1")

      assert status.success?, err
      assert_equal "No repeated queries in the last 10 requests.\n", out
    end
  end

  def test_prints_json_with_the_request_fields_the_other_commands_report
    in_app do |dir|
      db = create_database(dir)
      root = insert_root(db, "t1", "/posts")
      2.times { insert_query(db, "t1", root, COMMENTS, ms: 1, file: "app/models/post.rb", line: 9) }
      db.close

      out, err, status = flare(dir, "nplus1", "--json")

      assert status.success?, err
      request = JSON.parse(out).first
      assert_equal "t1", request["trace_id"]
      assert_equal "/posts", request["path"]
      assert_equal 2, request["queries"]
      assert_equal "PostsController", request["controller"]
      assert_equal [{
        "statement" => COMMENTS, "count" => 2, "total_ms" => 2.0,
        "sources" => [{ "location" => "app/models/post.rb:9", "count" => 2 }],
      }], request["repeated"]
    end
  end

  def test_checks_only_the_last_n_requests_and_skips_clean_ones
    in_app do |dir|
      db = create_database(dir)
      older = insert_root(db, "older", "/older", at: Time.now - 60)
      2.times { insert_query(db, "older", older, COMMENTS) }
      clean = insert_root(db, "clean", "/clean", at: Time.now - 30)
      insert_query(db, "clean", clean, COMMENTS)
      newer = insert_root(db, "newer", "/newer", at: Time.now)
      2.times { insert_query(db, "newer", newer, COMMENTS) }
      db.close

      out, _, = flare(dir, "nplus1", "--json")
      assert_equal %w[newer older], JSON.parse(out).map { |request| request["trace_id"] }

      out, _, = flare(dir, "nplus1", "--json", "--last", "2")
      assert_equal %w[newer], JSON.parse(out).map { |request| request["trace_id"] }
    end
  end

  def test_rejects_a_last_below_one
    in_app do |dir|
      create_database(dir).close

      _, err, status = flare(dir, "nplus1", "--last", "0")

      refute status.success?
      assert_match(/must be at least 1/, err)
    end
  end

  def test_explains_a_missing_database
    in_app do |dir|
      _, err, status = flare(dir, "nplus1")

      refute status.success?
      assert_match(/No Flare spans database/, err)
    end
  end

  def test_help_lists_the_command
    in_app do |dir|
      out, = flare(dir, "help")

      assert_match(/nplus1\s+Find queries repeated/, out)
    end
  end

  private

  def insert_root(db, trace, path, at: Time.now)
    insert_span(db, trace: trace, name: "GET #{path}", kind: "server", parent: ROOT_PARENT, ns: 10_000_000, at: at, properties: {
      "http.method" => "GET", "http.target" => path, "http.status_code" => 200,
      "code.namespace" => "PostsController", "code.function" => "index",
    })
    db.get_first_value("SELECT span_id FROM flare_spans WHERE trace_id = ?", [trace])
  end

  def insert_query(db, trace, root, statement, ms: 1, name: "Post Load", file: nil, line: nil)
    properties = { "db.statement" => statement, "name" => name }
    properties.merge!("code.filepath" => file, "code.lineno" => line) if file
    insert_span(db, trace: trace, name: "sql.active_record", kind: "internal", parent: root, ns: (ms * 1_000_000).to_i, at: Time.now, properties: properties)
  end
end
