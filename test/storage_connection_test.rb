# frozen_string_literal: true

require_relative "test_helper"
require "flare/storage/sqlite"

class StorageConnectionTest < Minitest::Test
  def test_storages_with_different_paths_on_one_thread_use_their_own_files
    Dir.mktmpdir do |dir|
      first = Flare::Storage::SQLite.new(File.join(dir, "first.sqlite3"))
      second_path = File.join(dir, "second.sqlite3")
      second = Flare::Storage::SQLite.new(second_path)

      first.clear_all # leaves a connection to first.sqlite3 cached on this thread
      second.clear_all

      assert_equal 0, second.count_requests
      assert_equal 0, first.count_requests
      db = SQLite3::Database.new(second_path)
      assert_includes db.execute("SELECT name FROM sqlite_master WHERE type = 'table'").flatten, "flare_spans"
    ensure
      db&.close
      first&.send(:close_connection)
      second&.send(:close_connection)
    end
  end
end
