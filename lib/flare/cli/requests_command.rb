# frozen_string_literal: true

require "json"
require "optparse"
require "time"
require_relative "output"

module Flare
  # Lists the most recent requests from the local development spans database,
  # so you (or a coding agent) can check a change without opening /flare.
  class RequestsCommand
    include CLI::Output

    DEFAULT_LIMIT = 10

    def initialize(argv)
      @limit = DEFAULT_LIMIT
      @json = false
      @database_path = File.join(Dir.pwd, "db", "flare.sqlite3")

      OptionParser.new do |opts|
        opts.banner = "Usage: flare requests [options]"
        opts.on("--last N", Integer, "Number of requests to show (default: #{DEFAULT_LIMIT})") { |n| @limit = n }
        opts.on("--json", "Print JSON instead of a table") { @json = true }
        opts.on("--db PATH", "Spans database (default: db/flare.sqlite3)") { |path| @database_path = File.expand_path(path) }
      end.parse!(argv)
    end

    def run
      unless File.exist?(@database_path)
        $stderr.puts "No Flare spans database at #{@database_path}."
        $stderr.puts "Start your app in development and make a request, or pass --db PATH."
        exit 1
      end

      requests = load_requests

      if @json
        puts JSON.pretty_generate(requests)
      elsif requests.empty?
        puts "No requests recorded yet."
      else
        requests.each { |request| puts format_row(request) }
      end
    end

    private

    def load_requests
      begin
        require "sqlite3"
      rescue LoadError
        $stderr.puts "The sqlite3 gem is required. Add `gem \"sqlite3\"` to your Gemfile and run with `bundle exec`."
        exit 1
      end
      require_relative "../storage"
      require_relative "../storage/sqlite"

      storage = Storage::SQLite.new(@database_path)
      requests = storage.list_requests(limit: @limit)
      query_counts = storage.count_queries_by_trace(requests.map { |r| r[:trace_id] })

      requests.map do |r|
        {
          trace_id: r[:trace_id],
          method: r[:http_method],
          path: r[:http_target],
          status: r[:http_status],
          duration_ms: r[:duration_ms].round(1),
          queries: query_counts.fetch(r[:trace_id], 0),
          controller: r[:controller],
          action: r[:action],
          started_at: Time.at(r[:start_timestamp] / 1_000_000_000r).iso8601(3),
        }
      end
    end

    def format_row(request)
      endpoint = [request[:controller], request[:action]].compact.join("#")
      [
        dim(request[:started_at]),
        request[:method].to_s.ljust(6),
        request[:status].to_s.ljust(3),
        format("%8.1fms", request[:duration_ms]),
        format("%4d queries", request[:queries]),
        request[:path],
        endpoint.empty? ? nil : dim(endpoint),
        dim(request[:trace_id]),
      ].compact.join("  ")
    end
  end
end
