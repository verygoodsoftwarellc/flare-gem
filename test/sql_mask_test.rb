# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/flare/sql_mask"

class SqlMaskTest < Minitest::Test
  def mask(sql, system = "postgresql")
    Flare::SqlMask.mask(sql, system)
  end

  def test_standard_strings_and_doubled_quotes
    assert_equal "SELECT * FROM t WHERE a = ? AND b = ?", mask("SELECT * FROM t WHERE a = 'x' AND b = 'it''s'")
  end

  def test_numbers_of_every_form
    assert_equal "a = ? b = ? c = ? d = ? e = ? t1 = ?", mask("a = 42 b = 1.5 c = 1e+9 d = 0xDEAD e = .5 t1 = 7")
  end

  def test_prefixed_strings
    assert_equal "SELECT ?, ?, ?, ?, ?", mask("SELECT X'ab', b'01', N'x', E'y', _utf8'z'")
  end

  def test_a_word_ending_in_a_prefix_letter_is_not_a_prefix
    assert_equal "SELECT name ?", mask("SELECT name 'x'")
  end

  def test_placeholders_become_one_form
    assert_equal "a = ? AND b = ?", mask("a = $1 AND b = ?")
  end

  def test_in_lists_collapse
    assert_equal "id IN (?)", mask("id IN (1, 2, $3)")
    assert_equal "id IN (?)", mask("id IN ( 1, 2 )")
  end

  def test_whitespace_collapses
    assert_equal "SELECT a FROM t", mask("  SELECT\n  a\tFROM   t  ")
  end

  def test_literal_inside_another_literal
    assert_equal "SELECT ?, ?", mask(%q{SELECT 'a /* b', 'hunter2 */'})
    assert_equal "SELECT ?, ?", mask(%q{SELECT '--', 'hunter2'})
    assert_equal "SELECT ?", mask(%q{SELECT '$$ hunter2 $$'})
    assert_equal 'SELECT ?', mask(%q{SELECT '"hunter2"'})
  end

  def test_comment_markers_inside_names_decide_nothing
    assert_equal %q{SELECT "a'b", ?}, mask(%q{SELECT "a'b", 'hunter2'})
    assert_equal %q{SELECT `a'b`, ?}, mask(%q{SELECT `a'b`, 'hunter2'}, "mysql2")
  end

  def test_quote_inside_a_comment_decides_nothing
    assert_equal "SELECT ? FROM t WHERE a = ?", mask("SELECT /* it's */ 1 FROM t WHERE a = 'hunter2'")
    assert_equal "SELECT ? FROM t WHERE a = ?", mask("SELECT 1 -- it's\nFROM t WHERE a = 'hunter2'")
  end

  def test_comments_are_removed_including_nested
    assert_equal "SELECT ?", mask("/* hunter2 */ SELECT /* a /* b */ hunter2 */ 1 -- hunter2")
  end

  def test_unterminated_forms_mask_the_rest
    [
      "SELECT 'hunter2 FROM t",
      "SELECT E'hunter2 FROM t",
      "SELECT $$hunter2 FROM t",
      "SELECT $tag$hunter2 $other$ FROM t",
      %q{SELECT "hunter2 FROM t},
      "SELECT `hunter2 FROM t",
    ].each do |sql|
      refute_includes mask(sql), "hunter2", sql
      refute_includes mask(sql), "FROM", sql
    end
    assert_equal "SELECT", mask("SELECT /* hunter2 FROM t")
  end

  def test_backslash_before_quote_masks_the_rest_on_every_system
    %w[postgresql sqlite mysql2 trilogy].each do |system|
      assert_equal "SELECT ?", mask(%q{SELECT 'a\\', 'hunter2' FROM t}, system), system
      assert_equal "SELECT ?", mask(%q{SELECT 'a\\'hunter2' FROM t}, system), system
    end
  end

  def test_even_backslashes_close_the_literal
    assert_equal "SELECT ?, ? FROM t", mask(%q{SELECT 'a\\\\', 'hunter2' FROM t})
  end

  def test_backslash_elsewhere_in_a_literal_is_plain
    assert_equal "SELECT ?, ?", mask(%q{SELECT 'a\\b', 'hunter2'})
  end

  def test_escape_strings_read_backslashes
    assert_equal "SELECT ?, ? FROM t", mask(%q{SELECT E'a\\'b', 'hunter2' FROM t})
  end

  def test_dollar_quoting
    assert_equal "SELECT ?, ?, ?", mask("SELECT $$hunter2$$, $a$ $$ hunter2 $a$, $1")
  end

  def test_dollar_inside_an_identifier_does_not_start_a_quote
    assert_equal "SELECT foo$bar$baz, ?", mask("SELECT foo$bar$baz, 'hunter2'")
  end

  def test_double_quotes_are_names_only_on_systems_that_read_them_so
    assert_equal 'SELECT "hunter2" FROM t', mask('SELECT "hunter2" FROM t', "postgresql")
    %w[mysql2 trilogy mysql mariadb sqlite sqlserver mystery].each do |system|
      assert_equal "SELECT ? FROM t", mask('SELECT "hunter2" FROM t', system), system
    end
  end

  def test_sqlite_keeps_double_quoted_names_only_where_they_can_only_be_names
    {
      'SELECT "posts".* FROM "posts" WHERE "posts"."id" = ? LIMIT ?' => 'SELECT "posts".* FROM "posts" WHERE "posts"."id" = ? LIMIT ?',
      'INSERT INTO "posts" ("title") VALUES (?)' => 'INSERT INTO "posts" (?) VALUES (?)',
      'UPDATE "posts" SET "title" = ?' => 'UPDATE "posts" SET ? = ?',
      'SELECT "x" FROM "a" JOIN "b"' => 'SELECT ? FROM "a" JOIN "b"',
      'SELECT "x from hunter2" FROM t' => "SELECT ? FROM t",
      'SELECT a FROM t WHERE b IS DISTINCT FROM "hunter2"' => "SELECT a FROM t WHERE b IS DISTINCT FROM ?",
      %(SELECT a FROM t WHERE b is distinct  from\n"hunter2") => "SELECT a FROM t WHERE b is distinct from ?",
      %(SELECT a FROM\n  "posts") => 'SELECT a FROM "posts"',
      'SELECT 1 WHERE a = "hunter2"' => "SELECT ? WHERE a = ?",
      'SELECT a FROM t WHERE b = "hunter2"."c' => "SELECT a FROM t WHERE b = ?.?",
    }.each { |sql, expected| assert_equal expected, mask(sql, "sqlite"), sql }
  end

  def test_sql_system_classifier
    %w[postgresql postgis mysql2 trilogy mariadb sqlite sqlite3 cockroachdb sqlserver mssql oracle oracleenhanced db2].each { |system| assert Flare::SqlMask.sql_system?(system), system }
    ["redis", "mongodb", "memcached", "elasticsearch", "cassandra", "etcd", "nosql", "mystery", "clickhouse", "bigquery", "snowflake"].each { |system| refute Flare::SqlMask.sql_system?(system), system }
    assert Flare::SqlMask.sql_system?(nil)
    assert Flare::SqlMask.sql_system?("")
  end

  def test_command_word_accepts_only_a_plain_leading_word
    assert_equal "AUTH", Flare::SqlMask.command_word(" AUTH hunter2")
    assert_equal "ping", Flare::SqlMask.command_word("ping")
    assert_equal "cluster.info", Flare::SqlMask.command_word("cluster.info x")
    ["hunter2 x", %({"a":"b"}), "", nil, "a" * 40, "a:b c"].each { |value| assert_nil Flare::SqlMask.command_word(value), value.inspect }
  end

  def test_double_quotes_are_values_when_the_system_is_unknown
    assert_equal "SELECT ?", mask('SELECT "hunter2"', nil)
  end

  def test_hash_starts_a_comment_only_on_mysql
    assert_equal "a ? FROM t", mask("a 1 # it's hunter2\nFROM t", "mysql2")
    assert_equal "a #>> ?", mask("a #>> '{b}'", "postgresql")
  end

  def test_non_ascii_and_invalid_bytes
    assert_equal "SELECT café, ?", mask("SELECT café, 'hunter2'")
    assert_equal "SELECT �?", mask("SELECT \xFF'hunter2'")
    assert_predicate mask("SELECT \xFF"), :valid_encoding?
  end

  def test_long_statements_are_cut_and_stay_masked
    tail = "'hunter2'"
    long = "SELECT #{"a, " * 10_000}#{tail}"

    masked = mask(long)

    assert_operator masked.bytesize, :<=, Flare::SqlMask::MAX_BYTES + Flare::SqlMask::TRUNCATED.bytesize
    assert masked.end_with?(Flare::SqlMask::TRUNCATED)
    refute_includes masked, "hunter2"
  end

  def test_a_cut_inside_a_literal_is_masked
    long = "SELECT '#{"hunter2 " * 5_000}"
    assert_equal "SELECT ? ...", mask(long)
  end

  def test_nil_and_empty
    assert_equal "", mask(nil)
    assert_equal "", mask("")
  end
end
