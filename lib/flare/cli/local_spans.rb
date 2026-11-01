# frozen_string_literal: true

require "optparse"
require "time"

module Flare
  module CLI
    # Read-only access to the local development spans database, for commands
    # that inspect it from the terminal. Explains a missing or unreadable
    # database and exits rather than printing a backtrace.
    module LocalSpans
      DEFAULT_LIMIT = 10

      class Unavailable < StandardError; end

      private

      # Parses the options these commands share, returning the other arguments.
      # Pass last_help for commands that read several requests.
      def parse_options(argv, banner:, last_help: nil)
        @limit = DEFAULT_LIMIT
        @json = false
        @database_path = default_database_path

        OptionParser.new do |opts|
          opts.banner = banner
          if last_help
            opts.on("--last N", Integer, "#{last_help} (default: #{DEFAULT_LIMIT})") do |n|
              raise OptionParser::InvalidArgument, "#{n} (must be at least 1)" if n < 1

              @limit = n
            end
          end
          opts.on("--json", "Print JSON instead of text") { @json = true }
          opts.on("--db PATH", "Spans database (default: db/flare.sqlite3)") { |path| @database_path = File.expand_path(path) }
        end.parse!(argv)
      rescue OptionParser::ParseError => e
        $stderr.puts e.message
        exit 1
      end

      def default_database_path
        File.join(Dir.pwd, "db", "flare.sqlite3")
      end

      # The fields every request-reading command reports, so their JSON stays
      # in step.
      def request_summary(span, method:, path:, status:, controller:, action:, queries:)
        {
          trace_id: span[:trace_id],
          method: method,
          path: without_query_string(path),
          status: status,
          duration_ms: span[:duration_ms].round(1),
          queries: queries,
          controller: controller,
          action: action,
          started_at: Time.at(span[:start_timestamp] / 1_000_000_000r).iso8601(3),
        }
      end

      def recent_requests(storage, limit)
        requests = storage.list_requests(limit: limit)
        query_counts = storage.count_queries_by_trace(requests.map { |r| r[:trace_id] })

        requests.map do |r|
          request_summary(r, method: r[:http_method], path: r[:http_target], status: r[:http_status],
            controller: r[:controller], action: r[:action], queries: query_counts.fetch(r[:trace_id], 0))
        end
      end

      # The statement with its values taken out, so one query run with different
      # values reads as the same query.
      def shape(statement)
        statement.to_s
          .gsub(%r{/\*.*?\*/}m, " ")
          .gsub(/\$((?:[A-Za-z_]\w*)?)\$.*?\$\1\$/m, "?")
          .gsub(/(?:\b[xben])?'(?:(?:[^'\\]|\\.|'')*'|(?:[^']|'')*')/i, "?")
          .gsub(/\$\d+/, "?")
          .gsub(/\b0x\h+\b/i, "?")
          .gsub(/\b\d+(?:\.\d+)?\b/, "?")
          .gsub(/\bIN\s*\(\s*\?(?:\s*,\s*\?)*\s*\)/i, "IN (?)")
          .gsub(/\s+/, " ")
          .strip
      end

      def without_query_string(url)
        url&.to_s&.split("?", 2)&.first
      end

      def source_location(props)
        return unless props["code.filepath"]

        [props["code.filepath"], props["code.lineno"]].compact.join(":")
      end

      def request_heading(request, title)
        [bold(title), request[:status], format("%.1fms", request[:duration_ms]), endpoint(request)].compact.join("  ")
      end

      def endpoint(request)
        name = [request[:controller], request[:action]].compact.join("#")
        name unless name.empty?
      end

      # For commands that end after one read: explains the problem and exits.
      def read_local_spans(database_path, &block)
        open_local_spans(database_path, &block)
      rescue Unavailable => e
        $stderr.puts e.message
        exit 1
      end

      # Closes the connection afterward, so a long-running caller sees a
      # database the app has since recreated.
      def open_local_spans(database_path)
        unless File.exist?(database_path)
          raise Unavailable, "No Flare spans database at #{database_path}.\n" \
            "Start your app in development and make a request, or pass --db PATH."
        end

        begin
          require "sqlite3"
        rescue LoadError
          raise Unavailable, "The sqlite3 gem is required. Add `gem \"sqlite3\"` to your Gemfile and run with `bundle exec`."
        end
        require_relative "../storage"
        require_relative "../storage/sqlite"

        storage = Storage::SQLite.new(database_path, readonly: true)
        begin
          yield storage
        rescue SQLite3::Exception => e
          raise Unavailable, "Could not read #{database_path}: #{e.message}"
        ensure
          storage.close_connection
        end
      end
    end
  end
end
