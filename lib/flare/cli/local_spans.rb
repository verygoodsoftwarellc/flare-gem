# frozen_string_literal: true

require "time"

module Flare
  module CLI
    # Read-only access to the local development spans database, for commands
    # that inspect it from the terminal. Explains a missing or unreadable
    # database and exits rather than printing a backtrace.
    module LocalSpans
      private

      def default_database_path
        File.join(Dir.pwd, "db", "flare.sqlite3")
      end

      # The fields `flare requests` and `flare request` both report, so their
      # JSON stays in step.
      def request_summary(span, method:, path:, status:, controller:, action:, queries:)
        {
          trace_id: span[:trace_id],
          method: method,
          path: path,
          status: status,
          duration_ms: span[:duration_ms].round(1),
          queries: queries,
          controller: controller,
          action: action,
          started_at: Time.at(span[:start_timestamp] / 1_000_000_000r).iso8601(3),
        }
      end

      def endpoint(request)
        name = [request[:controller], request[:action]].compact.join("#")
        name unless name.empty?
      end

      def read_local_spans(database_path)
        unless File.exist?(database_path)
          $stderr.puts "No Flare spans database at #{database_path}."
          $stderr.puts "Start your app in development and make a request, or pass --db PATH."
          exit 1
        end

        begin
          require "sqlite3"
        rescue LoadError
          $stderr.puts "The sqlite3 gem is required. Add `gem \"sqlite3\"` to your Gemfile and run with `bundle exec`."
          exit 1
        end
        require_relative "../storage"
        require_relative "../storage/sqlite"

        begin
          yield Storage::SQLite.new(database_path, readonly: true)
        rescue SQLite3::Exception => e
          $stderr.puts "Could not read #{database_path}: #{e.message}"
          exit 1
        end
      end
    end
  end
end
