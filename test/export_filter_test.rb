# frozen_string_literal: true

require_relative "test_helper"
require "flare/export_filter"

class ExportFilterTest < Minitest::Test
  FILTERED = Flare::ExportFilter::FILTERED

  def setup
    @filter = Flare::ExportFilter.new([:zipcode, "user.nickname", ->(key, value) { value.replace("masked") if key == "shout" }])
  end

  def filtered(name, value, **others)
    @filter.attributes({ name => value, **others })[name]
  end

  def test_url_attributes_under_old_and_new_names
    %w[http.url url.full].each do |name|
      assert_equal "https://x.test/a?password=#{FILTERED}&page=2",
        filtered(name, "https://user:pw@x.test/a?password=hunter2&page=2#frag"), name
    end
    assert_equal "/a?token=#{FILTERED}&page=2", filtered("http.target", "/a?token=hunter2&page=2#frag")
    assert_equal "token=#{FILTERED}&page=2", filtered("url.query", "token=hunter2&page=2")
    assert_equal "/a", filtered("url.path", "/a")
  end

  def test_the_apps_filters_apply_to_query_strings
    assert_equal "zipcode=#{FILTERED}", filtered("url.query", "zipcode=1")
    assert_equal "user[nickname]=#{FILTERED}&nickname=ok", filtered("url.query", "user[nickname]=x&nickname=ok")
    refute_includes filtered("url.query", "shout=hunter2"), "hunter2"
  end

  def test_query_string_forms
    assert_equal "user%5Bpassword%5D=#{FILTERED}", filtered("url.query", "user%5Bpassword%5D=hunter2")
    assert_equal "a=1;token=#{FILTERED}", filtered("url.query", "a=1;token=hunter2")
    assert_equal FILTERED, filtered("url.query", "hunter2")
    assert_equal FILTERED, filtered("url.query", "%ZZ=hunter2")
    assert_equal "next=#{FILTERED}", filtered("url.query", "next=https%3A%2F%2Fx.test%3Ftoken%3Dhunter2")
    assert_equal "", filtered("url.query", "")
  end

  def test_default_filters_apply_with_an_empty_app_list
    filter = Flare::ExportFilter.new
    %w[password passwd api_key apikey X-Api-Key token secret access_token auth key sig code].each do |name|
      assert_equal "#{name}=#{FILTERED}", filter.attributes({ "url.query" => "#{name}=hunter2" })["url.query"], name
    end
    assert_equal "page=2&author=me", filter.attributes({ "url.query" => "page=2&author=me" })["url.query"]
  end

  def test_userinfo_in_awkward_urls
    assert_equal "redis://x.test:6379/0", filtered("http.url", "redis://:hunter2@x.test:6379/0")
    assert_equal "https://#{FILTERED}", filtered("http.url", "https://user:hun/ter2@x.test/a")
    assert_equal "https://#{FILTERED}", filtered("http.url", "https://user:hun#ter2@x.test/a")
    assert_equal "https://x.test/@bob", filtered("http.url", "https://x.test/@bob")
    assert_equal "http://[::1]:80/a", filtered("http.url", "http://[::1]:80/a")
    assert_equal "//x.test/a", filtered("http.url", "//u:p@x.test/a")
  end

  def test_host_attributes_drop_userinfo
    assert_equal "x.test:80", filtered("http.host", "user:hunter2@x.test:80")
    assert_equal "x.test", filtered("server.address", "x.test")
  end

  def test_statements_under_every_name
    %w[db.statement db.query.text db.query sql statement].each do |name|
      assert_equal "SELECT ?", filtered(name, "SELECT 'hunter2'", "db.system": "sqlite"), name
    end
  end

  def test_statements_use_the_attributes_system
    attrs = @filter.attributes("db.system" => "postgresql", "db.statement" => 'SELECT "a"')
    assert_equal 'SELECT "a"', attrs["db.statement"]
    attrs = @filter.attributes("db.system" => "mysql2", "db.statement" => 'SELECT "a"')
    assert_equal "SELECT ?", attrs["db.statement"]
    attrs = @filter.attributes("db.system.name" => "postgresql", "db.query.text" => 'SELECT "a"')
    assert_equal 'SELECT "a"', attrs["db.query.text"]
  end

  def test_a_statement_that_masks_to_nothing_stays_present
    assert_equal "?", @filter.attributes("db.system" => "sqlite", "db.statement" => "/* hunter2 */")["db.statement"]
  end

  def test_non_sql_stores_keep_only_the_command
    attrs = @filter.attributes("db.system" => "redis", "db.statement" => "AUTH hunter2")
    assert_equal "AUTH ?", attrs["db.statement"]
    attrs = @filter.attributes("db.system" => "mongodb", "db.statement" => '{"find":"hunter2"}')
    assert_equal "?", attrs["db.statement"]
  end

  def test_mail_job_and_exception_contents_are_left_out
    %w[to from cc bcc subject args arguments params headers body payload exception exception.message exception.stacktrace email.to.address].each do |name|
      assert_equal FILTERED, filtered(name, "hunter2"), name
    end
    assert_equal FILTERED, filtered("params", %w[hunter2])
  end

  def test_cache_keys_keep_their_leading_word
    assert_equal "views/?", filtered("key", "views/posts/hunter2")
    assert_equal "rack:?", filtered("key", "rack:attack:hunter2")
    assert_equal "?", filtered("key", "hunter2")
    assert_equal "?", filtered("key", "user1/hunter2")
  end

  def test_what_the_trace_view_and_rules_read_is_kept
    filter = Flare::ExportFilter.new([:code, :name, :host, :method, :route, :system, :identifier])
    attrs = {
      "code.namespace" => "UsersController", "code.function" => "show", "code.filepath" => "app/a.rb", "code.lineno" => 3,
      "http.route" => "/users/:id", "http.request.method" => "GET", "http.method" => "GET", "http.status_code" => 200,
      "messaging.system" => "active_job", "messaging.destination" => "default", "flare.rule_id" => 1,
      "name" => "User Load", "identifier" => "/app/views/a.erb", "db.system" => "sqlite", "db.name" => "primary",
      "mailer" => "AppMailer", "store" => "Store", "hit" => true, "user_agent.original" => "curl/8 (+https://x.test/?a=b)",
    }
    assert_equal attrs, filter.attributes(attrs)
  end

  def test_other_attributes_are_filtered_by_name
    assert_equal FILTERED, filtered("password", "hunter2")
    assert_equal FILTERED, filtered("zipcode", 46601)
    assert_equal FILTERED, filtered("http.request.header.authorization", "Bearer hunter2")
    assert_equal FILTERED, filtered("http.request.header.cookie", "a=hunter2")
    assert_equal 200, filtered("count_total", 200)
    assert_equal "gold", filtered("plan", "gold")
  end

  def test_other_attributes_are_scanned_for_urls_pairs_and_sql
    assert_equal "see https://x.test/a?token=#{FILTERED}", filtered("note", "see https://u:hunter2@x.test/a?token=hunter2#hunter2")
    assert_equal "password=#{FILTERED}", filtered("note", "password=hunter2 page=2")
    assert_equal "token: #{FILTERED}", filtered("note", "token: hunter2")
    assert_equal "SELECT ?", filtered("note", "SELECT 'hunter2'")
    assert_equal ["token=#{FILTERED}", "ok"], filtered("tags", ["token=hunter2", "ok"])
  end

  def test_json_looking_values_are_left_out
    [%({"password":"hunter2"}), %({"a":{"secret":"hunter2"}}), %( [{"token":"hunter2"}]), %({"password"=>"hunter2"})].each do |value|
      assert_equal FILTERED, filtered("note", value), value
      assert_equal FILTERED, @filter.name(value), value
    end
  end

  def test_json_inside_text_is_filtered
    refute_includes filtered("note", %(sent {"token":"hunter2"})), "hunter2"
    refute_includes @filter.name(%(sent {"token":"hunter2"})), "hunter2"
  end

  def test_a_value_shaped_like_a_url_gets_no_exemption
    ["password=//hunter2", "secret: //hunter2", "token://hunter2", "next=//u:hunter2@x/?token=hunter2", "next=//hunter2"].each do |value|
      refute_includes filtered("note", value), "hunter2", value
      refute_includes @filter.name(value), "hunter2", value
    end
  end

  def test_urls_in_text_are_read_whole
    assert_equal "see https://x.test/a?page=2 ok", filtered("note", "see https://x.test/a?page=2 ok")
    assert_equal "see //x.test/a ok", filtered("note", "see //u:hunter2@x.test/a ok")
  end

  def test_a_sensitive_key_masks_the_rest_of_its_line
    [
      "authorization: Bearer hunter2", "Authorization=Basic hunter2 more", "cookie: a=1; b=hunter2", "password = two hunter2",
      %q(password="a\"hunter2"), %q(password='a\'hunter2'), "pass%77ord=hunter2", "user%5Btoken%5D=hunter2", %(password="a\nhunter2"),
    ].each do |value|
      refute_includes filtered("note", value), "hunter2", value
      refute_includes @filter.name(value), "hunter2", value
    end
    assert_equal "password=#{FILTERED}\nok=1", filtered("note", "password=a b\nok=1")
  end

  def test_bearer_and_basic_credentials_without_a_key
    assert_equal "sent Bearer #{FILTERED} ok", filtered("note", "sent Bearer hunter2 ok")
    assert_equal "sent Basic #{FILTERED} ok", filtered("note", "sent Basic aHVudGVyMjpodW50ZXIy ok")
    assert_equal "basic plan", filtered("note", "basic plan")
  end

  def test_ordinary_text_is_kept
    ["gold plan", "at 12:30:11 done", "plan: gold", "a=1 b=2"].each { |value| assert_equal value, filtered("note", value) }
  end

  def test_statements_for_systems_that_are_not_known_sql_keep_only_the_command
    {
      "etcd" => ["PUT hunter2", "PUT ?"], "cassandra" => ["SELECT * FROM hunter2", "SELECT ?"], "neo4j" => [%(MATCH (n {p:"hunter2"})), "MATCH ?"],
      "couchbase" => [%({"a":"hunter2"}), "?"], "mystery" => ["hunter2 x", "?"], "memcached" => ["set hunter2", "set ?"],
    }.each do |system, (statement, expected)|
      assert_equal expected, @filter.attributes("db.system" => system, "db.statement" => statement)["db.statement"], system
    end
  end

  def test_pairs_are_found_after_any_punctuation_and_in_sql_looking_text
    ["GET /token=hunter2", "foo::token=hunter2", "DROP token=hunter2", "SHOW password: hunter2", "CALL secret=hunter2"].each do |value|
      refute_includes filtered("note", value), "hunter2", value
      refute_includes @filter.name(value), "hunter2", value
    end
  end

  def test_scanning_text_stays_bounded
    ["a" * 100_000, "a:" * 100_000, "a=1 " * 30_000, "https://" * 10_000, "." * 100_000].each do |value|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      filtered("note", value)
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1, value[0, 10]
    end
  end

  def test_db_operations_must_be_a_plain_word
    assert_equal "SELECT", filtered("db.operation", "SELECT")
    assert_equal "find", filtered("db.operation.name", "find")
    assert_equal "?", filtered("db.operation", "hunter2 x")
    assert_equal "?", filtered("db.operation.name", "a b")
  end

  def test_sql_systems_are_masked_as_sql
    %w[postgresql postgis mysql2 trilogy sqlite cockroachdb sqlserver oracle].each do |system|
      assert_equal "SELECT a FROM t WHERE b = ?", @filter.attributes("db.system" => system, "db.statement" => "SELECT a FROM t WHERE b = 'hunter2'")["db.statement"], system
    end
  end

  def test_userinfo_shapes_in_paths_and_without_a_scheme
    assert_equal "https://x.test/#{FILTERED}?z=1", filtered("http.url", "https://x.test/a@hunter2?z=1")
    assert_equal "https://x.test/p/#{FILTERED}", filtered("http.url", "https://x.test/p/u:hunter2@y")
    assert_equal "/a/#{FILTERED}?d=1", filtered("http.target", "/a/b:hunter2@c?d=1")
    assert_equal "/#{FILTERED}", filtered("url.path", "/u:hunter2@c")
    assert_equal "x.test/a", filtered("http.url", "user:hunter2@x.test/a")
    assert_equal "https://x.test/@bob/posts", filtered("http.url", "https://x.test/@bob/posts")
    assert_equal "/@bob", filtered("url.path", "/@bob")
  end

  def test_sql_is_recognized_past_comments_parentheses_and_other_starters
    ["/* c */ SELECT 'hunter2'", "-- c\nSELECT 'hunter2'", "(SELECT 'hunter2')", "( ( SELECT 'hunter2'))", "/* SELECT 'hunter2'", "EXPLAIN SELECT 'hunter2'", "CALL f('hunter2')", "EXEC f 'hunter2'", "EXECUTE f('hunter2')", "VALUES ('hunter2')", "COPY t FROM 'hunter2'", "TRUNCATE 'hunter2'", "SHOW 'hunter2'", "DROP 'hunter2'"].each do |value|
      refute_includes filtered("note", value), "hunter2", value
      refute_includes @filter.name(value), "hunter2", value
    end
  end

  def test_span_names
    assert_equal "sql.active_record", @filter.name("sql.active_record")
    assert_equal "GET /users/:id", @filter.name("GET /users/:id")
    assert_equal "GET /a?token=#{FILTERED}", @filter.name("GET /a?token=hunter2")
    assert_equal "SELECT ?", @filter.name("SELECT 'hunter2'")
    assert_equal "DELETE FROM t WHERE id > ?", @filter.name("DELETE FROM t WHERE id > 5")
    assert_equal "GET /a?next=#{FILTERED}", @filter.name("GET /a?next=https%3A%2F%2Fx.test%3Ftoken%3Dhunter2")
    assert_equal "POST https://x.test/a", @filter.name("POST https://u:hunter2@x.test/a")
    assert_nil @filter.name(nil)
  end

  def test_a_filter_that_raises_does_not_let_the_value_through
    filter = Flare::ExportFilter.new([->(_key, _value) { raise "boom" }])
    assert_equal FILTERED, filter.attributes({ "note" => "hunter2" })["note"]
    assert_equal FILTERED, filter.attributes({ "url.query" => "a=hunter2" })["url.query"]
  end

  def test_invalid_bytes
    assert_equal "�", filtered("note", "\xFF")
    assert_equal "a=�", filtered("url.query", "a=\xFF")
  end

  def test_long_values_are_bounded
    long = "a=" + ("b" * 100_000)
    assert_operator filtered("note", long).bytesize, :<=, Flare::ExportFilter::MAX_TEXT_BYTES
  end

  def test_nil_attributes
    assert_equal({}, @filter.attributes(nil))
  end
end
