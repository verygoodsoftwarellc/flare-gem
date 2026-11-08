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
      reaped = false
      pid = fork do
        reader.close
        begin
          result = { same_connection: storage.send(:connection).equal?(original), count: storage.count_requests }
          storage.send(:close_connection)
        rescue StandardError => error
          result = { error: "#{error.class}: #{error.message}" }
        end
        writer.write(Marshal.dump(result))
        writer.close
        exit! 0
      end
      writer.close
      result, child_status = Timeout.timeout(5) do
        payload = Marshal.load(reader.read)
        _, status = Process.wait2(pid)
        reaped = true
        [payload, status]
      end
      assert_predicate child_status, :success?
      refute result[:error], result[:error]
      refute result[:same_connection], "forked reader reused the parent's SQLite connection"
      assert_equal 0, result[:count]
      assert_same original, storage.send(:connection)
      assert_equal 0, storage.count_requests
    ensure
      if pid && !reaped
        begin
          Process.kill(:KILL, pid)
        rescue Errno::ESRCH
          nil
        ensure
          Process.wait(pid) rescue Errno::ECHILD
        end
      end
      reader&.close
      writer&.close unless writer&.closed?
      storage&.send(:close_connection)
    end
  end
end
