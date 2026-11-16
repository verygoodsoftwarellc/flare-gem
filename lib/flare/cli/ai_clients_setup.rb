# frozen_string_literal: true

require "json"
require "open3"
require "fileutils"
require_relative "output"

module Flare
  # Points the AI clients on this machine at Flare's hosted MCP server, as
  # `flare-cli setup` does. Each client signs in to Flare itself the first
  # time it connects, so no token is written anywhere. A client that already
  # has a different `flare` server is left alone.
  class AIClientsSetup
    include CLI::Output

    DEFAULT_HOST = "https://flare.am"
    SERVER_NAME = "flare"
    FIRST_PROMPT = "Using Flare, what's slowest in production over the last 24 hours?"
    CLIENTS = {
      claude: "Claude Code",
      codex: "Codex",
      cursor: "Cursor",
      claude_desktop: "Claude Desktop",
    }.freeze

    # Runs the clients' own CLIs. `capture` returns [output, success];
    # `attached` shares the terminal, because Codex may start its sign-in
    # right away and print a URL to open.
    class Runner
      def capture(*command)
        output, status = Open3.capture2e(*command)
        [output, status.success?]
      rescue SystemCallError => e
        [e.message, false]
      end

      def attached(*command)
        system(*command) == true
      end
    end

    def initialize(host: ENV.fetch("FLARE_HOST", DEFAULT_HOST), input: $stdin, env: ENV, home: Dir.home, platform: RUBY_PLATFORM, runner: Runner.new)
      @host = host.chomp("/")
      @url = "#{@host}/mcp"
      @input = input
      @env = env
      @home = home
      @platform = platform
      @runner = runner
    end

    # `flare setup` asks first, since this changes other apps' settings.
    # `flare connect` is the asking. Returns false if any client failed to
    # connect, so `flare connect` can exit non-zero.
    def run(ask: true)
      @failed = false
      puts
      puts bold("Connect your AI assistant")

      clients = CLIENTS.keys.select { |client| installed?(client) }
      if clients.empty?
        puts "  No AI clients found. To connect one later, add #{url} to it as a remote MCP server."
        puts "  See #{@host}/docs/mcp"
      elsif !ask || confirmed?(clients)
        connect(clients)
      end
      !@failed
    end

    private

    attr_reader :url

    # A closed stdin (a script, an agent) counts as no.
    def confirmed?(clients)
      print "  Found #{clients.map { |client| CLIENTS[client] }.join(", ")}. Connect #{clients.one? ? "it" : "them"} to Flare? (Y/n): "
      answer = @input.gets
      reply = answer.to_s.strip.downcase
      return true if answer && (reply.empty? || reply.start_with?("y"))

      puts if answer.nil?
      puts "  Skipped. Run #{bold("flare connect")} #{answer.nil? ? "in a terminal" : "any time"} to connect them."
      false
    end

    def connect(clients)
      next_steps = clients.filter_map do |client|
        hint = send("connect_#{client}")
        "#{CLIENTS[client]}: #{hint}" if hint
      end

      puts
      if next_steps.any?
        puts "  Next:"
        next_steps.each { |line| puts "    #{line}" }
        puts
        puts "  Then ask: #{FIRST_PROMPT.inspect}"
      else
        puts "  Ask: #{FIRST_PROMPT.inspect}"
      end
    end

    def installed?(client)
      case client
      when :claude then executable?("claude")
      when :codex then executable?("codex")
      when :cursor then executable?("cursor") || File.directory?(File.join(@home, ".cursor"))
      when :claude_desktop then File.directory?(claude_desktop_directory)
      end
    end

    def connect_claude
      current = claude_config.dig("mcpServers", SERVER_NAME)
      if current
        return already(:claude) if current["type"] == "http" && current["url"] == url
        return different(:claude, "run #{bold("claude mcp remove #{SERVER_NAME} -s user")}")
      end

      command = ["claude", "mcp", "add", "--transport", "http", "-s", "user", SERVER_NAME, url]
      output, success = @runner.capture(*command)
      return failed(:claude, command: command, output: output) unless success

      connected(:claude, "run /mcp, choose #{SERVER_NAME}, and sign in")
    end

    def connect_codex
      output, success = @runner.capture("codex", "mcp", "get", SERVER_NAME, "--json")
      if success
        current = parse_json(output)
        transport = current["transport"] || {}
        matching = transport["type"] == "streamable_http" && transport["url"] == url
        return different(:codex, "run #{bold("codex mcp remove #{SERVER_NAME}")}") unless matching
        return already(:codex) unless current["enabled"] == false
      elsif !output.downcase.match?(/not found|no mcp server/)
        return failed(:codex, command: ["codex", "mcp", "get", SERVER_NAME], output: output)
      end

      command = ["codex", "mcp", "add", SERVER_NAME, "--url", url]
      return failed(:codex, command: command) unless @runner.attached(*command)

      connected(:codex, "run `codex mcp login #{SERVER_NAME}` if it hasn't asked you to sign in")
    end

    # Sets mcpServers.flare in ~/.cursor/mcp.json, keeping everything else in it.
    def connect_cursor
      path = File.join(@home, ".cursor", "mcp.json")
      document = File.exist?(path) ? JSON.parse(File.read(path)) : {}
      servers = document["mcpServers"] ||= {}
      entry = { "url" => url }

      if servers.key?(SERVER_NAME)
        return already(:cursor) if servers[SERVER_NAME] == entry
        return different(:cursor, "remove #{SERVER_NAME} from ~/.cursor/mcp.json")
      end

      servers[SERVER_NAME] = entry
      write_atomically(path, JSON.pretty_generate(document) + "\n")
      connected(:cursor, "open Cursor Settings → MCP and sign in to #{SERVER_NAME}", where: "~/.cursor/mcp.json")
    rescue JSON::ParserError, SystemCallError => e
      failed(:cursor, output: e.message)
    end

    # Claude Desktop keeps remote servers in your account, not a file.
    def connect_claude_desktop
      "in Settings, add a custom connector with the URL #{url}"
    end

    # Each outcome prints one line and returns what's left to do in the client.
    def connected(client, hint, where: nil)
      puts "  #{checkmark} Connected #{CLIENTS[client]}#{" in #{where}" if where}"
      hint
    end

    def already(client)
      puts "  #{checkmark} #{CLIENTS[client]} is already connected to Flare"
      nil
    end

    def different(client, how)
      puts "  #{warn_mark} #{CLIENTS[client]} already has a different #{SERVER_NAME} server, so it was left alone."
      puts "    To replace it, #{how}, then run #{bold("flare connect")}."
      nil
    end

    def failed(client, command: nil, output: nil)
      @failed = true
      reason = output.to_s.lines.map(&:strip).reject(&:empty?).first
      puts "  #{xmark} Couldn't connect #{CLIENTS[client]}#{": #{reason}" if reason}"
      puts "    Run it yourself: #{command.join(" ")}" if command
      nil
    end

    def claude_config
      directory = @env.fetch("CLAUDE_CONFIG_DIR", "").empty? ? @home : @env["CLAUDE_CONFIG_DIR"]
      path = File.join(directory, ".claude.json")
      File.exist?(path) ? parse_json(File.read(path)) : {}
    end

    def parse_json(text)
      value = JSON.parse(text)
      value.is_a?(Hash) ? value : {}
    rescue JSON::ParserError
      {}
    end

    def claude_desktop_directory
      case @platform
      when /darwin/ then File.join(@home, "Library", "Application Support", "Claude")
      when /mingw|mswin/ then File.join(@env.fetch("APPDATA", File.join(@home, "AppData", "Roaming")), "Claude")
      else File.join(@env.fetch("XDG_CONFIG_HOME", File.join(@home, ".config")), "Claude")
      end
    end

    def executable?(name)
      @env.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
        path = File.join(directory, name)
        File.file?(path) && File.executable?(path)
      end
    end

    # Writes to a temporary file and renames it, so a crash never leaves the
    # client with half a config. Keeps the file's permissions.
    def write_atomically(path, contents)
      FileUtils.mkdir_p(File.dirname(path))
      mode = File.exist?(path) ? File.stat(path).mode & 0o777 : 0o644
      temporary = "#{path}.flare-#{Process.pid}"
      File.write(temporary, contents)
      File.chmod(mode, temporary)
      File.rename(temporary, path)
    ensure
      File.delete(temporary) if temporary && File.exist?(temporary)
    end
  end
end
