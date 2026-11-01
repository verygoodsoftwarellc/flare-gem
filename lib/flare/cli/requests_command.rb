# frozen_string_literal: true

require "json"
require_relative "local_spans"
require_relative "output"

module Flare
  # Lists the most recent requests from the local development spans database,
  # so you (or a coding agent) can check a change without opening /flare.
  class RequestsCommand
    include CLI::LocalSpans
    include CLI::Output

    def initialize(argv)
      parse_options(argv, banner: "Usage: flare requests [options]", last_help: "Number of requests to show")
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
