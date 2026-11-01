# frozen_string_literal: true

require "json"
require_relative "local_spans"
require_relative "output"

module Flare
  # Finds queries repeated within recent requests in the local development
  # spans database, and the code that ran them, so you (or a coding agent) can
  # spot an N+1 and confirm a fix without opening /flare.
  class Nplus1Command
    include CLI::LocalSpans
    include CLI::Output

    MINIMUM_REPEATS = 2
    # What Active Record names its own bookkeeping, which repeats by design.
    # Transaction statements from elsewhere have no name, so they're also
    # matched by their text.
    IGNORED_QUERY_NAMES = %w[TRANSACTION SCHEMA].freeze

    def initialize(argv)
      parse_options(argv, banner: "Usage: flare nplus1 [options]", last_help: "Number of requests to check")
    end

    def run
      requests = read_local_spans(@database_path) { |storage| load_requests(storage) }

      if @json
        puts JSON.pretty_generate(requests)
      elsif requests.empty?
        puts "No repeated queries in recent requests (checked up to #{@limit})."
      else
        requests.each { |request| print_request(request) }
      end
    end

    private

    def load_requests(storage)
      recent_requests(storage, @limit).filter_map do |request|
        repeated = repeated_queries(storage.spans_for_trace(request[:trace_id]))
        request.merge(repeated: repeated) if repeated.any?
      end
    end

    def repeated_queries(spans)
      spans.select { |span| query?(span) }
        .group_by { |span| shape(span[:properties]["db.statement"]) }
        .select { |_, queries| queries.size >= MINIMUM_REPEATS }
        .map { |statement, queries| summarize(statement, queries) }
        .sort_by { |query| [-query[:count], -query[:total_ms]] }
    end

    def query?(span)
      props = span[:properties]
      statement = props["db.statement"]
      return false unless statement && Storage::SQLite::SPAN_CATEGORIES["queries"].any? { |pattern| span[:name].downcase.include?(pattern) }

      !IGNORED_QUERY_NAMES.include?(props["name"]) && !Storage::SQLite::TRANSACTION_STATEMENTS.include?(statement.to_s.strip.upcase)
    end

    # The statement with its values taken out, so one query run with different
    # values reads as the same query.
    def shape(statement)
      statement.to_s
        .gsub(%r{/\*.*?\*/}m, " ")
        .gsub(/'(?:[^']|'')*'/, "?")
        .gsub(/\$\d+/, "?")
        .gsub(/\b\d+(?:\.\d+)?\b/, "?")
        .gsub(/\bIN\s*\(\s*\?(?:\s*,\s*\?)*\s*\)/i, "IN (?)")
        .gsub(/\s+/, " ")
        .strip
    end

    def summarize(statement, queries)
      {
        statement: statement,
        count: queries.size,
        total_ms: queries.sum { |query| query[:duration_ms] }.round(1),
        sources: sources(queries),
      }
    end

    def sources(queries)
      queries.filter_map { |query| source_location(query[:properties]) }.tally
        .sort_by { |_, count| -count }
        .map { |location, count| { location: location, count: count } }
    end

    def print_request(request)
      puts "#{request_heading(request, "#{request[:method]} #{request[:path]}")}  #{dim(request[:trace_id])}"

      request[:repeated].each do |query|
        puts format("%4dx %7.1fms  %s", query[:count], query[:total_ms], query[:statement])
        query[:sources].each { |source| puts dim(format("%7dx  %s", source[:count], source[:location])) }
      end
    end
  end
end
