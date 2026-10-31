# frozen_string_literal: true

require "json"
require "optparse"
require_relative "local_spans"
require_relative "output"

module Flare
  # Shows what one request did, from the local development spans database, so
  # you (or a coding agent) can read its timeline without opening /flare. Trace
  # ids come from `flare requests`.
  class RequestCommand
    include CLI::LocalSpans
    include CLI::Output

    USAGE = "Usage: flare request <trace_id> [options]"

    def initialize(argv)
      @json = false
      @database_path = default_database_path

      arguments = OptionParser.new do |opts|
        opts.banner = USAGE
        opts.on("--json", "Print JSON instead of text") { @json = true }
        opts.on("--db PATH", "Spans database (default: db/flare.sqlite3)") { |path| @database_path = File.expand_path(path) }
      end.parse!(argv)

      unless arguments.size == 1
        $stderr.puts USAGE
        exit 1
      end
      @trace_id = arguments.first
    rescue OptionParser::ParseError => e
      $stderr.puts e.message
      exit 1
    end

    def run
      request = read_local_spans(@database_path) { |storage| load_request(storage) }

      unless request
        $stderr.puts "No request with trace id #{@trace_id}. Run `flare requests` to list recent ones."
        exit 1
      end

      if @json
        puts JSON.pretty_generate(request)
      else
        print_request(request)
      end
    end

    private

    def load_request(storage)
      root = storage.find_request(@trace_id)
      return unless root

      spans = storage.spans_for_trace(@trace_id)
      props = root[:properties]

      request_summary(root,
        method: props["http.request.method"] || props["http.method"],
        path: props["url.path"] || props["http.target"],
        status: props["http.response.status_code"] || props["http.status_code"],
        controller: props["code.namespace"],
        action: props["code.function"],
        queries: storage.count_queries_by_trace([@trace_id]).fetch(@trace_id, 0)).merge(
          name: root[:name],
          exceptions: spans.flat_map { |span| exceptions(span) },
          spans: spans.reject { |span| span[:id] == root[:id] }.map { |span| timeline_entry(span, root) },
        )
    end

    def exceptions(span)
      span[:events].select { |event| event[:name] == "exception" }.map do |event|
        {
          type: event[:properties]["exception.type"],
          message: event[:properties]["exception.message"],
          stacktrace: event[:properties]["exception.stacktrace"],
        }
      end
    end

    def timeline_entry(span, root)
      props = span[:properties]
      {
        name: span[:name],
        offset_ms: ((span[:start_timestamp] - root[:start_timestamp]) / 1_000_000.0).round(1),
        duration_ms: span[:duration_ms].round(1),
        detail: detail(props),
        source: source(props),
      }
    end

    def detail(props)
      statement = props["db.statement"]
      return statement.to_s.gsub(/\s+/, " ").strip if statement

      identifier = props["identifier"]
      return identifier.to_s.sub(%r{\A.*/app/views/}, "") if identifier

      props["http.url"] || props["url.full"]
    end

    def source(props)
      return unless props["code.filepath"]

      [props["code.filepath"], props["code.lineno"]].compact.join(":")
    end

    def print_request(request)
      title = request[:method] ? "#{request[:method]} #{request[:path]}" : request[:name]
      puts [bold(title), request[:status], format("%.1fms", request[:duration_ms]), endpoint(request)].compact.join("  ")
      puts "Started #{request[:started_at]}  #{request[:queries]} queries"

      request[:exceptions].each do |exception|
        puts red("Exception: #{[exception[:type], exception[:message]].compact.join(": ")}")
      end

      return if request[:spans].empty?

      puts
      puts dim(format("%9s %9s", "offset", "duration"))
      request[:spans].each { |span| puts format_span(span) }
    end

    def format_span(span)
      label = span[:detail] ? "#{span[:name]}: #{span[:detail]}" : span[:name]
      [
        format("%7.1fms %7.1fms", span[:offset_ms], span[:duration_ms]),
        label,
        span[:source] && dim(span[:source]),
      ].compact.join("  ")
    end
  end
end
