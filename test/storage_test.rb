# frozen_string_literal: true

require_relative "test_helper"
require "flare/storage/sqlite"

class StorageTest < Minitest::Test
  def test_sqlite_implements_every_base_method_with_the_same_parameters
    Flare::Storage::Base.public_instance_methods(false).each do |name|
      implementation = Flare::Storage::SQLite.instance_method(name)

      assert_equal Flare::Storage::SQLite, implementation.owner, "SQLite does not implement Base##{name}"
      assert_equal Flare::Storage::Base.instance_method(name).parameters, implementation.parameters, "Base##{name} parameters differ from SQLite"
    end
  end

  def test_prune_removes_old_and_over_limit_spans_with_their_rows
    with_storage do |storage, path|
      insert_span(path, "old", Time.now - 7200)
      insert_span(path, "over_limit", Time.now - 60)
      insert_span(path, "newest", Time.now)

      storage.prune(retention_hours: 1, max_spans: 1)

      assert_equal ["newest"], rows(path, "SELECT name FROM flare_spans")
      assert_equal ["newest"], rows(path, "SELECT name FROM flare_events")
      assert_equal %w[newest newest], rows(path, "SELECT value FROM flare_properties ORDER BY owner_type")
    end
  end

  def test_prune_rolls_back_when_a_statement_fails
    with_storage do |storage, path|
      insert_span(path, "old", Time.now - 7200)
      connection = storage.send(:connection)
      def connection.execute(sql, *args)
        raise ::SQLite3::BusyException, "database is locked" if sql.start_with?("DELETE FROM flare_spans")

        super
      end

      assert_raises(::SQLite3::BusyException) { storage.prune(retention_hours: 1, max_spans: 10) }

      assert_equal ["old"], rows(path, "SELECT name FROM flare_spans")
      assert_equal ["old"], rows(path, "SELECT name FROM flare_events")
      assert_equal 2, rows(path, "SELECT id FROM flare_properties").size, "span left without its properties"
    end
  end

  private

  # Storage caches its connection per thread, so use a fresh thread to avoid
  # picking up a connection another test left open.
  def with_storage
    Thread.new do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "flare.sqlite3")
        storage = Flare::Storage::SQLite.new(path)
        storage.send(:setup_database)
        yield storage, path
      ensure
        storage&.send(:close_connection)
      end
    end.join
  end

  def insert_span(path, name, created_at)
    at = created_at.iso8601(6)
    db = SQLite3::Database.new(path)
    db.execute(<<~SQL, [name, at, at])
      INSERT INTO flare_spans (name, kind, span_id, trace_id, start_timestamp, end_timestamp, created_at, updated_at)
      VALUES (?, 'internal', 's', 't', 0, 0, ?, ?)
    SQL
    span_id = db.last_insert_row_id
    db.execute("INSERT INTO flare_events (span_id, name, created_at, updated_at) VALUES (?, ?, ?, ?)", [span_id, name, at, at])
    event_id = db.last_insert_row_id
    db.execute("INSERT INTO flare_properties (key, value, owner_type, owner_id, created_at, updated_at) VALUES ('k', ?, 'Flare::Span', ?, ?, ?)", [name, span_id, at, at])
    db.execute("INSERT INTO flare_properties (key, value, owner_type, owner_id, created_at, updated_at) VALUES ('k', ?, 'Flare::Event', ?, ?, ?)", [name, event_id, at, at])
  ensure
    db&.close
  end

  def rows(path, sql)
    db = SQLite3::Database.new(path)
    db.execute(sql).flatten
  ensure
    db&.close
  end
end
