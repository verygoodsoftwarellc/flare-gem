# frozen_string_literal: true

require "json"
require "optparse"
require_relative "local_spans"
require_relative "output"

module Flare
  # Lists the most recent requests from the local development spans database,
  # so you (or a coding agent) can check a change without opening /flare.
  class RequestsCommand
    include CLI::LocalSpans
    include CLI::Output

    DEFAULT_LIMIT = 10

    def initialize(argv)
      @limit = DEFAULT_LIMIT
      @json = false
      @database_path = default_database_path

      OptionParser.new do |opts|
        opts.banner = "Usage: flare requests [options]"
        opts.on("--last N", Integer, "Number of requests to show (default: #{DEFAULT_LIMIT})") do |n|
          raise OptionParser::InvalidArgument, "#{n} (must be at least 1)" if n < 1

          @limit = n
        end
        opts.on("--json", "Print JSON instead of a table") { @json = true }
        opts.on("--db PATH", "Spans database (default: db/flare.sqlite3)") { |path| @database_path = File.expand_path(path) }
      end.parse!(argv)
    rescue OptionParser::ParseError => e
      $stderr.puts e.message
      exit 1
    end

    def run
      requests = read_local_spans(@database_path) { |storage| recent_requests(storage, @limit) }

      if @json
        puts JSON.pretty_generate(requests)
      elsif requests.empty?
        puts "No requests recorded yet."
      else
        requests.each { |request| puts format_row(request) }
      end
    end

    private

    def format_row(request)
      [
        dim(request[:started_at]),
        request[:method].to_s.ljust(6),
        request[:status].to_s.ljust(3),
        format("%8.1fms", request[:duration_ms]),
        format("%4d queries", request[:queries]),
        request[:path],
        endpoint(request)&.then { |name| dim(name) },
        dim(request[:trace_id]),
      ].compact.join("  ")
    end
  end
end
