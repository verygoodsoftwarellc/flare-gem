# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "flare/cli/ai_clients_setup"

class AIClientsSetupTest < Minitest::Test
  URL = "https://flare.am/mcp"

  # Stands in for the clients' CLIs: records each command and answers with
  # whatever the test set up for it.
  class FakeRunner
    attr_reader :commands

    def initialize(responses = {})
      @responses = responses
      @commands = []
    end

    def capture(*command)
      @commands << command
      @responses.fetch(command.first(3), ["", true])
    end

    def attached(*command)
      @commands << command
      @responses.fetch(command.first(3), ["", true]).last
    end
  end

  def setup
    @home = Dir.mktmpdir
    @bin = File.join(@home, "bin")
    FileUtils.mkdir_p(@bin)
  end

  def teardown
    FileUtils.rm_rf(@home)
  end

  def test_connects_claude_code_codex_and_cursor_and_explains_claude_desktop
    install("claude", "codex")
    FileUtils.mkdir_p(File.join(@home, ".cursor"))
    FileUtils.mkdir_p(File.join(@home, "Library", "Application Support", "Claude"))
    runner = FakeRunner.new(["codex", "mcp", "get"] => ["Error: No MCP server named 'flare' found.", false])

    out = run_setup(runner, input: "\n")

    assert_includes runner.commands, ["claude", "mcp", "add", "--transport", "http", "-s", "user", "flare", URL]
    assert_includes runner.commands, ["codex", "mcp", "add", "flare", "--url", URL]
    assert_equal({ "mcpServers" => { "flare" => { "url" => URL } } }, cursor_config)
    assert_includes out, "Found Claude Code, Codex, Cursor, Claude Desktop."
    assert_includes out, "Claude Code: run /mcp, choose flare, and sign in"
    assert_includes out, "Claude Desktop: in Settings, add a custom connector with the URL #{URL}"
    assert_includes out, "Then ask:"
  end

  def test_changes_nothing_when_the_answer_is_no
    install("claude")
    runner = FakeRunner.new

    out = run_setup(runner, input: "n\n")

    assert_empty runner.commands
    assert_includes out, "Skipped"
  end

  def test_changes_nothing_when_nobody_can_answer
    install("claude")
    runner = FakeRunner.new

    out = run_setup(runner, input: "")

    assert_empty runner.commands
    assert_includes out, "flare connect"
  end

  def test_flare_connect_does_not_ask
    install("claude")
    runner = FakeRunner.new

    run_setup(runner, input: "", ask: false)

    assert_equal [["claude", "mcp", "add", "--transport", "http", "-s", "user", "flare", URL]], runner.commands
  end

  def test_points_to_the_docs_when_no_client_is_installed
    out = run_setup(FakeRunner.new, input: "\n")

    assert_includes out, "No AI clients found"
    assert_includes out, "https://flare.am/docs/mcp"
  end

  def test_leaves_claude_code_alone_when_already_connected
    install("claude")
    write_json(File.join(@home, ".claude.json"), "mcpServers" => { "flare" => { "type" => "http", "url" => URL } })
    runner = FakeRunner.new

    out = run_setup(runner, input: "y\n")

    assert_empty runner.commands
    assert_includes out, "Claude Code is already connected to Flare"
    assert_includes out, "  Ask:"
  end

  def test_leaves_a_different_claude_code_flare_server_alone
    install("claude")
    write_json(File.join(@home, ".claude.json"), "mcpServers" => { "flare" => { "type" => "stdio", "command" => "flare-cli" } })
    runner = FakeRunner.new

    out = run_setup(runner, input: "y\n")

    assert_empty runner.commands
    assert_includes out, "already has a different flare server"
    assert_includes out, "claude mcp remove flare -s user"
  end

  def test_leaves_codex_alone_when_already_connected
    install("codex")
    current = { "name" => "flare", "enabled" => true, "transport" => { "type" => "streamable_http", "url" => URL } }
    runner = FakeRunner.new(["codex", "mcp", "get"] => [JSON.generate(current), true])

    out = run_setup(runner, input: "y\n")

    assert_equal [["codex", "mcp", "get", "flare", "--json"]], runner.commands
    assert_includes out, "Codex is already connected to Flare"
  end

  def test_leaves_a_different_codex_flare_server_alone
    install("codex")
    current = { "name" => "flare", "enabled" => true, "transport" => { "type" => "stdio", "command" => "flare-cli" } }
    runner = FakeRunner.new(["codex", "mcp", "get"] => [JSON.generate(current), true])

    out = run_setup(runner, input: "y\n")

    assert_equal 1, runner.commands.size
    assert_includes out, "codex mcp remove flare"
  end

  def test_keeps_other_cursor_servers_and_settings
    path = File.join(@home, ".cursor", "mcp.json")
    write_json(path, "mcpServers" => { "github" => { "url" => "https://example.com/mcp" } }, "other" => true)
    File.chmod(0o600, path)

    run_setup(FakeRunner.new, input: "y\n")

    assert_equal(
      { "mcpServers" => { "github" => { "url" => "https://example.com/mcp" }, "flare" => { "url" => URL } }, "other" => true },
      cursor_config
    )
    assert_equal 0o600, File.stat(path).mode & 0o777
  end

  def test_leaves_a_different_cursor_flare_server_alone
    path = File.join(@home, ".cursor", "mcp.json")
    write_json(path, "mcpServers" => { "flare" => { "command" => "flare-cli", "args" => ["mcp"] } })

    out = run_setup(FakeRunner.new, input: "y\n")

    assert_equal({ "command" => "flare-cli", "args" => ["mcp"] }, cursor_config.dig("mcpServers", "flare"))
    assert_includes out, "already has a different flare server"
  end

  def test_reports_a_failed_client_and_carries_on
    install("claude")
    FileUtils.mkdir_p(File.join(@home, ".cursor"))
    runner = FakeRunner.new(["claude", "mcp", "add"] => ["boom\n", false])

    out = run_setup(runner, input: "y\n")

    assert_includes out, "Couldn't connect Claude Code: boom"
    assert_includes out, "Run it yourself: claude mcp add --transport http -s user flare #{URL}"
    assert_equal URL, cursor_config.dig("mcpServers", "flare", "url")
  end

  # Regression: ISSUE-001 — flare connect exited 0 when a client failed to connect
  # Found by /qa on 2026-11-16
  # Report: .gstack/qa-reports/qa-report-flare-connect-2026-11-16.md
  def test_run_says_whether_every_client_connected
    install("claude")
    assert run_setup(FakeRunner.new, input: "", ask: false, result: true)
    refute run_setup(FakeRunner.new(["claude", "mcp", "add"] => ["boom\n", false]), input: "", ask: false, result: true)
  end

  private

  def run_setup(runner, input:, ask: true, result: false)
    setup = Flare::AIClientsSetup.new(
      host: "https://flare.am/",
      input: StringIO.new(input),
      env: { "PATH" => @bin },
      home: @home,
      platform: "arm64-darwin25",
      runner: runner
    )
    connected = nil
    out, = capture_io { connected = setup.run(ask: ask) }
    result ? connected : out
  end

  def install(*names)
    names.each do |name|
      path = File.join(@bin, name)
      File.write(path, "#!/bin/sh\n")
      File.chmod(0o755, path)
    end
  end

  def write_json(path, value)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(value))
  end

  def cursor_config
    JSON.parse(File.read(File.join(@home, ".cursor", "mcp.json")))
  end
end
