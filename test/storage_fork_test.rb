# frozen_string_literal: true

require_relative "test_helper"
require "flare/storage/sqlite"
require "timeout"

class StorageForkTest < Minitest::Test
  def test_child_opens_its_own_connection_and_parent_can_keep_reading
    skip "fork is unavailable" unless Process.respond_to?(:fork)

    Dir.mktmpdir do |dir|
      storage = Flare::Storage::SQLite.new(File.join(dir, "flare.sqlite3"))
      storage.send(:setup_database)
      original = storage.send(:connection)
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        result = [storage.send(:connection).equal?(original), storage.count_requests]
        writer.write(Marshal.dump(result))
        storage.send(:close_connection)
        writer.close
        exit! 0
      end
      writer.close
      same_connection, count = Timeout.timeout(5) { Marshal.load(reader.read) }
      Process.wait(pid)
      assert_predicate $?, :success?
      refute same_connection, "forked reader reused the parent's SQLite connection"
      assert_equal 0, count
      assert_same original, storage.send(:connection)
      assert_equal 0, storage.count_requests
    ensure
      reader&.close
      writer&.close unless writer&.closed?
      storage&.send(:close_connection)
    end
  end
end
