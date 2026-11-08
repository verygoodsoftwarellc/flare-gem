# frozen_string_literal: true

require_relative "test_helper"
require "flare/storage/sqlite"

class StorageExceptionEventsTest < Minitest::Test
  def test_exception_lists_and_counts_exclude_other_events
    Dir.mktmpdir do |dir|
      path = File.join(dir, "flare.sqlite3")
      storage = Flare::Storage::SQLite.new(path)
      storage.send(:setup_database)
      db = SQLite3::Database.new(path)
      %w[exception checkpoint].each do |name|
        db.execute("INSERT INTO flare_spans (name, kind, span_id, trace_id, parent_span_id, start_timestamp, end_timestamp, created_at, updated_at) VALUES (?, 'internal', ?, ?, 'p', 1, 2, 'now', 'now')", [name, name, name])
        db.execute("INSERT INTO flare_events (name, span_id, created_at, updated_at) VALUES (?, ?, 'now', 'now')", [name, db.last_insert_row_id])
      end
      exception_span_id = db.get_first_value("SELECT id FROM flare_spans WHERE name = 'exception'")
      db.execute("INSERT INTO flare_events (name, span_id, created_at, updated_at) VALUES ('checkpoint', ?, 'now', 'now')", [exception_span_id])
      db.close

      assert_equal ["exception"], storage.list_exception_spans.map { |span| span[:name] }
      assert_equal 1, storage.count_exception_spans
      assert_equal ["exception"], storage.list_spans_by_category("exceptions").map { |span| span[:name] }
      assert_equal 1, storage.count_spans_by_category("exceptions")
      assert_equal ["exception"], storage.list_exception_spans(name: "exc").map { |span| span[:name] }
      assert_equal 1, storage.count_exception_spans(name: "exc")
      assert_empty storage.list_exception_spans(name: "checkpoint")
      assert_equal 0, storage.count_exception_spans(name: "checkpoint")
    ensure
      db&.close unless db&.closed?
      storage&.send(:close_connection)
    end
  end
end
