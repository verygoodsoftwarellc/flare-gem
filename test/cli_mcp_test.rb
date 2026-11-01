# frozen_string_literal: true

require "minitest/autorun"
require_relative "cli_spans_support"

class CLIMcpTest < Minitest::Test
  include CLISpansSupport

  COMMENTS = 'SELECT "comments".* FROM "comments" WHERE "comments"."post_id" = ?'

  def test_handshake_lists_read_only_tools_and_ignores_notifications
    in_app do |dir|
      init, tools, ping = mcp(dir,
        { id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } } },
        { method: "notifications/initialized" },
        { id: 2, method: "tools/list" },
        { id: 3, method: "ping" })

      assert_equal 1, init["id"]
      assert_equal "2025-06-18", init.dig("result", "protocolVersion")
      assert_equal "flare", init.dig("result", "serverInfo", "name")
      assert_equal({}, init.dig("result", "capabilities", "tools"))

      assert_equal %w[list_requests get_request find_n_plus_one], tools.dig("result", "tools").map { |tool| tool["name"] }
      assert(tools.dig("result", "tools").all? { |tool| tool.dig("annotations", "readOnlyHint") })
      assert_equal({}, ping["result"])
    end
  end

  def test_offers_its_newest_protocol_for_one_it_does_not_know
    in_app do |dir|
      init = mcp(dir, { id: 1, method: "initialize", params: { protocolVersion: "1999-01-01" } }).first

      assert_equal "2025-11-25", init.dig("result", "protocolVersion")
    end
  end

  def test_tools_read_requests_timelines_and_repeated_queries
    in_app do |dir|
      seed_n_plus_one(dir)

      requests = tool_data(dir, "list_requests")
      assert_equal ["t1"], requests.map { |request| request["trace_id"] }
      assert_equal 3, requests.first["queries"]

      request = tool_data(dir, "get_request", trace_id: "t1")
      assert_equal "/posts", request["path"]
      assert_equal "app/views/posts/index.html.erb:3", request["spans"].first["source"]

      repeated = tool_data(dir, "find_n_plus_one", last: 1)
      assert_equal COMMENTS, repeated.first["repeated"].first["statement"]
      assert_equal 3, repeated.first["repeated"].first["count"]
    end
  end

  def test_requests_read_without_their_values
    in_app do |dir|
      db = create_database(dir)
      root = insert_root(db, "t1", "/posts?page=2")
      insert_query(db, "t1", root, "SELECT * FROM posts WHERE title = 'First' AND views > 10 AND id IN (1, 2)")
      insert_span(db, trace: "t1", name: "HTTP GET", kind: "client", parent: root, ns: 1_000_000, at: Time.now,
        properties: { "http.url" => "https://api.example.com/items?page=2" })
      db.close

      assert_equal "/posts", tool_data(dir, "list_requests").first["path"]

      request = tool_data(dir, "get_request", trace_id: "t1")
      assert_equal "/posts", request["path"]
      assert_equal ["SELECT * FROM posts WHERE title = ? AND views > ? AND id IN (?)", "https://api.example.com/items"],
        request["spans"].map { |span| span["detail"] }
    end
  end

  def test_every_kind_of_literal_reads_as_a_placeholder
    in_app do |dir|
      db = create_database(dir)
      root = insert_root(db, "t1", "/posts?page=2")
      db.execute("UPDATE flare_spans SET name = ? WHERE trace_id = ?", ["GET /posts?page=2", "t1"])
      insert_query(db, "t1", root, %q(SELECT $$one$$, $tag$two$tag$, 0xBEEF, x'AB', E'three', 'it\\'s four' FROM posts WHERE id = $1))
      db.close

      request = tool_data(dir, "get_request", trace_id: "t1")
      assert_equal "GET /posts", request["name"]
      assert_equal "SELECT ?, ?, ?, ?, ?, ? FROM posts WHERE id = ?", request["spans"].first["detail"]
    end
  end

  def test_double_quotes_are_values_only_on_mysql
    in_app do |dir|
      db = create_database(dir)
      root = insert_root(db, "t1", "/posts")
      insert_span(db, trace: "t1", name: "sql.active_record", kind: "internal", parent: root, ns: 1_000_000, at: Time.now,
        properties: { "db.statement" => 'SELECT * FROM `posts` WHERE title = "First" AND score = 1.5e3', "db.system" => "trilogy", "name" => "Post Load" })
      insert_query(db, "t1", root, 'SELECT "posts".* FROM "posts"')
      db.close

      assert_equal ["SELECT * FROM `posts` WHERE title = ? AND score = ?", 'SELECT "posts".* FROM "posts"'],
        tool_data(dir, "get_request", trace_id: "t1")["spans"].map { |span| span["detail"] }
    end
  end

  def test_last_limits_the_requests_read
    in_app do |dir|
      db = create_database(dir)
      insert_root(db, "older", "/a", at: Time.now - 60)
      insert_root(db, "newer", "/b")
      db.close

      assert_equal ["newer"], tool_data(dir, "list_requests", last: 1).map { |request| request["trace_id"] }
    end
  end

  def test_tool_problems_are_tool_errors_and_the_server_keeps_answering
    in_app do |dir|
      missing_db, ping = mcp(dir, tool_call("list_requests"), { id: 9, method: "ping" })
      assert tool_error?(missing_db)
      assert_includes tool_text(missing_db), "No Flare spans database"
      assert_equal({}, ping["result"])

      seed_n_plus_one(dir)
      [
        [tool_call("get_request", trace_id: "nope"), "No request with trace id nope"],
        [tool_call("get_request", trace_id: "--last"), "No request with trace id --last"],
        [tool_call("get_request"), "trace_id is required"],
        [tool_call("list_requests", last: 0), "at least 1"],
        [tool_call("find_n_plus_one", last: "5"), "at least 1"],
      ].each do |call, message|
        response = mcp(dir, call).first
        assert tool_error?(response), call.inspect
        assert_includes tool_text(response), message
      end
    end
  end

  def test_a_corrupt_database_is_a_tool_error
    in_app do |dir|
      FileUtils.mkdir_p(File.join(dir, "db"))
      File.write(File.join(dir, "db", "flare.sqlite3"), "not a database" * 100)

      response = mcp(dir, tool_call("list_requests")).first

      assert tool_error?(response)
      assert_includes tool_text(response), "Could not read"
    end
  end

  def test_protocol_errors
    in_app do |dir|
      unknown_method, unknown_tool = mcp(dir, { id: 1, method: "resources/list" }, { id: 2, method: "tools/call", params: { name: "nope" } })
      assert_equal(-32_601, unknown_method.dig("error", "code"))
      assert_equal(-32_602, unknown_tool.dig("error", "code"))

      out, _err, status = flare(dir, "mcp", stdin_data: "not json\n[1]\n\n")
      assert status.success?
      parse_error, not_a_message = out.lines.map { |line| JSON.parse(line) }
      assert_equal(-32_700, parse_error.dig("error", "code"))
      assert_equal(-32_600, not_a_message.dig("error", "code"))
    end
  end

  def test_sees_a_database_recreated_while_it_runs
    in_app do |dir|
      seed_n_plus_one(dir)

      Open3.popen2(*flare_command("mcp"), chdir: dir) do |stdin, stdout, _thread|
        ask = lambda do
          stdin.puts JSON.generate(tool_call("list_requests").merge(jsonrpc: "2.0"))
          JSON.parse(tool_text(JSON.parse(stdout.gets))).map { |request| request["trace_id"] }
        end

        assert_equal ["t1"], ask.call

        FileUtils.rm_f(Dir.glob(File.join(dir, "db", "flare.sqlite3*")))
        db = create_database(dir)
        insert_root(db, "t2", "/fresh")
        db.close

        assert_equal ["t2"], ask.call
      end
    end
  end

  def test_database_path_option
    in_app do |dir|
      seed_n_plus_one(dir, "custom/spans.sqlite3")

      response = mcp(dir, tool_call("list_requests"), args: ["--db", "custom/spans.sqlite3"]).first

      refute tool_error?(response)
      assert_includes tool_text(response), "t1"
    end
  end

  def test_runs_without_a_utf8_locale
    in_app do |dir|
      db = create_database(dir)
      insert_root(db, "t1", "/café")
      db.close

      out, err, status = Open3.capture3({ "LANG" => "C", "LC_ALL" => "C", "RUBYLIB" => $LOAD_PATH.join(File::PATH_SEPARATOR) }, *flare_command("mcp"),
        stdin_data: JSON.generate(tool_call("get_request", trace_id: "t1").merge(jsonrpc: "2.0")) + "\n", chdir: dir)

      assert status.success?, err
      assert_includes JSON.parse(out, symbolize_names: false).dig("result", "content", 0, "text"), "/café"
    end
  end

  private

  def seed_n_plus_one(dir, path = "db/flare.sqlite3")
    db = create_database(dir, path)
    root = insert_root(db, "t1", "/posts")
    3.times { insert_query(db, "t1", root, COMMENTS, ms: 1.5, file: "app/views/posts/index.html.erb", line: 3) }
    db.close
  end

  def mcp(dir, *messages, args: [])
    input = messages.map { |message| JSON.generate(message.merge(jsonrpc: "2.0")) }.join("\n") + "\n"
    out, err, status = flare(dir, "mcp", *args, stdin_data: input)
    assert status.success?, err
    assert_empty err
    out.lines.map { |line| JSON.parse(line) }
  end

  def tool_call(name, **arguments)
    { id: 1, method: "tools/call", params: { name: name, arguments: arguments } }
  end

  def tool_data(dir, name, **arguments)
    response = mcp(dir, tool_call(name, **arguments)).first
    refute tool_error?(response), tool_text(response)
    JSON.parse(tool_text(response))
  end

  def tool_text(response)
    response.dig("result", "content", 0, "text")
  end

  def tool_error?(response)
    response.dig("result", "isError") == true
  end
end
