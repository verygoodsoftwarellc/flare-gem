# frozen_string_literal: true

require "json"
require "optparse"
require_relative "local_spans"
require_relative "nplus1_command"
require_relative "request_command"

module Flare
  # A local MCP server over stdio, so a coding agent can read the development
  # spans database with tools instead of running `flare requests`, `flare
  # request` and `flare nplus1` itself. Read-only. Stdout carries only protocol
  # messages, one JSON-RPC message per line.
  class McpCommand
    include CLI::LocalSpans

    # Newest first. These only differ in ways the tools below don't use.
    PROTOCOL_VERSIONS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze

    PARSE_ERROR = -32_700
    INVALID_REQUEST = -32_600
    METHOD_NOT_FOUND = -32_601
    INVALID_PARAMS = -32_602

    class InvalidArgument < StandardError; end

    LAST_SCHEMA = { type: "integer", minimum: 1, description: "Number of recent requests to read (default: #{CLI::LocalSpans::DEFAULT_LIMIT})" }.freeze

    TOOLS = [
      {
        name: "list_requests",
        description: "List recent requests to this app in development, newest first, with status, duration, query count and trace id.",
        inputSchema: { type: "object", properties: { last: LAST_SCHEMA } },
        annotations: { readOnlyHint: true },
      },
      {
        name: "get_request",
        description: "Show what one request did, in order: each query, view render and HTTP call with its timing and the code that ran it, plus any exceptions.",
        inputSchema: {
          type: "object",
          properties: { trace_id: { type: "string", description: "Trace id from list_requests" } },
          required: ["trace_id"],
        },
        annotations: { readOnlyHint: true },
      },
      {
        name: "find_n_plus_one",
        description: "Find queries repeated within recent requests, ignoring bound values, with the code that ran them. Use it to spot an N+1 and to confirm a fix.",
        inputSchema: { type: "object", properties: { last: LAST_SCHEMA } },
        annotations: { readOnlyHint: true },
      },
    ].freeze

    def initialize(argv)
      @database_path = default_database_path

      OptionParser.new do |opts|
        opts.banner = "Usage: flare mcp [options]"
        opts.on("--db PATH", "Spans database (default: db/flare.sqlite3)") { |path| @database_path = File.expand_path(path) }
      end.parse!(argv)
    rescue OptionParser::ParseError => e
      $stderr.puts e.message
      exit 1
    end

    def run
      $stdin.set_encoding(Encoding::UTF_8)

      $stdin.each_line do |line|
        next if line.strip.empty?

        response = respond_to_line(line)
        puts JSON.generate(response) if response
      end
    rescue Interrupt, Errno::EPIPE
      # The client went away, which is how a stdio server is meant to stop.
    end

    private

    def respond_to_line(line)
      message = JSON.parse(line)
      return error(nil, INVALID_REQUEST, "Expected a single JSON-RPC message") unless message.is_a?(Hash)

      respond_to(message)
    rescue JSON::ParserError, EncodingError
      error(nil, PARSE_ERROR, "Could not parse the message as JSON")
    end

    def respond_to(message)
      id = message["id"]
      # A message with no id is a notification, which never gets a response.
      return unless message.key?("id")

      params = message["params"].is_a?(Hash) ? message["params"] : {}

      case message["method"]
      when "initialize" then result(id, initialize_result(params))
      when "ping" then result(id, {})
      when "tools/list" then result(id, { tools: TOOLS })
      when "tools/call" then call_tool(id, params)
      else error(id, METHOD_NOT_FOUND, "Unknown method: #{message["method"]}")
      end
    end

    def initialize_result(params)
      requested = params["protocolVersion"]

      {
        protocolVersion: PROTOCOL_VERSIONS.include?(requested) ? requested : PROTOCOL_VERSIONS.first,
        capabilities: { tools: {} },
        serverInfo: { name: "flare", version: Flare::VERSION },
      }
    end

    def call_tool(id, params)
      name = params["name"]
      return error(id, INVALID_PARAMS, "Unknown tool: #{name}") unless TOOLS.any? { |tool| tool[:name] == name }

      arguments = params["arguments"].is_a?(Hash) ? params["arguments"] : {}
      result(id, tool_text(JSON.pretty_generate(run_tool(name, arguments))))
    rescue InvalidArgument, CLI::LocalSpans::Unavailable => e
      result(id, tool_text(e.message, is_error: true))
    rescue StandardError => e
      result(id, tool_text("#{name} failed: #{e.class}: #{e.message}", is_error: true))
    end

    def run_tool(name, arguments)
      case name
      when "list_requests"
        last = last_argument(arguments)
        open_local_spans(@database_path) { |storage| recent_requests(storage, last) }
      when "get_request"
        trace_id = trace_id_argument(arguments)
        # "--" so an id can't be read as an option.
        request = open_local_spans(@database_path) { |storage| RequestCommand.new(["--", trace_id]).load_request(storage) }
        request || raise(InvalidArgument, "No request with trace id #{trace_id}. Use list_requests to find recent ones.")
      when "find_n_plus_one"
        last = last_argument(arguments)
        open_local_spans(@database_path) { |storage| Nplus1Command.new(["--last", last.to_s]).load_requests(storage) }
      end
    end

    def last_argument(arguments)
      last = arguments.fetch("last", CLI::LocalSpans::DEFAULT_LIMIT)
      raise InvalidArgument, "last must be an integer of at least 1" unless last.is_a?(Integer) && last >= 1

      last
    end

    def trace_id_argument(arguments)
      trace_id = arguments["trace_id"]
      raise InvalidArgument, "trace_id is required" unless trace_id.is_a?(String) && !trace_id.empty?

      trace_id
    end

    def tool_text(text, is_error: false)
      content = { content: [{ type: "text", text: text }] }
      is_error ? content.merge(isError: true) : content
    end

    def result(id, value)
      { jsonrpc: "2.0", id: id, result: value }
    end

    def error(id, code, message)
      { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
    end
  end
end
