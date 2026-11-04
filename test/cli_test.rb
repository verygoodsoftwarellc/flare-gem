# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "stringio"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "flare/cli"
require "flare/cli/output"
require "flare/cli/setup_command"
require "flare/cli/doctor_command"
require "flare/cli/status_command"

class CLITest < Minitest::Test
  def test_version_command
    out, = capture_io { Flare::CLI.start(["version"]) }
    assert_match(/flare \d+\.\d+\.\d+/, out)
  end

  def test_version_flag
    out, = capture_io { Flare::CLI.start(["--version"]) }
    assert_match(/flare \d+\.\d+\.\d+/, out)
  end

  def test_help_command
    out, = capture_io { Flare::CLI.start(["help"]) }
    assert_includes out, "Usage: flare <command>"
    assert_includes out, "setup"
    assert_includes out, "doctor"
    assert_includes out, "status"
  end

  def test_help_with_no_args
    out, = capture_io { Flare::CLI.start([]) }
    assert_includes out, "Usage: flare <command>"
  end

  def test_unknown_command_exits
    assert_raises(SystemExit) do
      capture_io { Flare::CLI.start(["bogus"]) }
    end
  end

  def test_commands_includes_doctor_and_status
    assert_includes Flare::CLI::COMMANDS, "doctor"
    assert_includes Flare::CLI::COMMANDS, "status"
  end
end

class CLIOutputTest < Minitest::Test
  include Flare::CLI::Output

  def test_green_with_tty
    $stdout.stub(:tty?, true) do
      assert_equal "\e[32mhello\e[0m", green("hello")
    end
  end

  def test_green_without_tty
    $stdout.stub(:tty?, false) do
      assert_equal "hello", green("hello")
    end
  end

  def test_red_with_tty
    $stdout.stub(:tty?, true) do
      assert_equal "\e[31mhello\e[0m", red("hello")
    end
  end

  def test_bold_with_tty
    $stdout.stub(:tty?, true) do
      assert_equal "\e[1mhello\e[0m", bold("hello")
    end
  end

  def test_bold_without_tty
    $stdout.stub(:tty?, false) do
      assert_equal "hello", bold("hello")
    end
  end

  def test_checkmark_with_tty
    $stdout.stub(:tty?, true) do
      assert_includes checkmark, "✓"
    end
  end

  def test_checkmark_without_tty
    $stdout.stub(:tty?, false) do
      assert_includes checkmark, "✓"
    end
  end
end

class SetupCommandInitializerTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @original_dir = Dir.pwd
    Dir.chdir(@dir)
  end

  def teardown
    Dir.chdir(@original_dir)
    FileUtils.remove_entry(@dir)
  end

  def test_creates_initializer
    cmd = Flare::SetupCommand.new(force: false)
    capture_io { cmd.send(:create_initializer) }

    path = File.join(@dir, "config/initializers/flare.rb")
    assert File.exist?(path)
    content = File.read(path)
    assert_includes content, "Flare.configure"
    assert_includes content, "config.spans_enabled"
    assert_includes content, "config.metrics_enabled"
    assert_includes content, "config.metrics_flush_interval"
    assert_includes content, "Custom Instrumentation"
    assert_includes content, "app.geocoding"
  end

  def test_skips_existing_initializer_without_force
    FileUtils.mkdir_p(File.join(@dir, "config/initializers"))
    File.write(File.join(@dir, "config/initializers/flare.rb"), "# existing")

    cmd = Flare::SetupCommand.new(force: false)
    out, = capture_io { cmd.send(:create_initializer) }

    assert_equal "# existing", File.read(File.join(@dir, "config/initializers/flare.rb"))
    assert_includes out, "already exists"
    assert_includes out, "--force"
  end

  def test_overwrites_existing_initializer_with_force
    FileUtils.mkdir_p(File.join(@dir, "config/initializers"))
    File.write(File.join(@dir, "config/initializers/flare.rb"), "# existing")

    cmd = Flare::SetupCommand.new(force: true)
    out, = capture_io { cmd.send(:create_initializer) }

    content = File.read(File.join(@dir, "config/initializers/flare.rb"))
    refute_equal "# existing", content
    assert_includes content, "Flare.configure"
    assert_includes out, "Overwrote"
  end
end

class SetupCommandGitignoreTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @original_dir = Dir.pwd
    Dir.chdir(@dir)
  end

  def teardown
    Dir.chdir(@original_dir)
    FileUtils.remove_entry(@dir)
  end

  def test_adds_entries_to_gitignore
    File.write(File.join(@dir, ".gitignore"), "/tmp\n")

    cmd = Flare::SetupCommand.new(force: false)
    cmd.instance_variable_set(:@saved_to_dotenv, true)
    capture_io { cmd.send(:add_gitignore_entries) }

    contents = File.read(File.join(@dir, ".gitignore"))
    assert_includes contents, ".env"
    assert_includes contents, "flare.sqlite3*"
  end

  def test_skips_existing_gitignore_entries
    File.write(File.join(@dir, ".gitignore"), ".env\nflare.sqlite3*\n")

    cmd = Flare::SetupCommand.new(force: false)
    out, = capture_io { cmd.send(:add_gitignore_entries) }

    refute_includes out, "Added"
  end

  def test_skips_env_when_a_new_rails_app_already_ignores_it
    File.write(File.join(@dir, ".gitignore"), "/.env*\nflare.sqlite3*\n")

    cmd = Flare::SetupCommand.new
    cmd.instance_variable_set(:@saved_to_dotenv, true)
    capture_io { cmd.send(:add_gitignore_entries) }

    assert_equal "/.env*\nflare.sqlite3*\n", File.read(File.join(@dir, ".gitignore"))
  end

  # Setup skips auth when FLARE_KEY is already in .env, but that .env holds
  # the key all the same.
  def test_adds_env_when_the_key_is_already_in_it
    File.write(File.join(@dir, ".gitignore"), "/tmp\n")
    File.write(File.join(@dir, ".env"), "FLARE_KEY=existing_key\n")

    out, = capture_io { Flare::SetupCommand.new.send(:add_gitignore_entries) }

    assert_equal "/tmp\n.env\nflare.sqlite3*\n", File.read(File.join(@dir, ".gitignore"))
    assert_includes out, "Added .env, flare.sqlite3*"
  end

  def test_leaves_env_alone_when_the_key_is_not_in_it
    File.write(File.join(@dir, ".gitignore"), "/tmp\n")
    File.write(File.join(@dir, ".env"), "OTHER_VAR=hello\nFLARE_KEY=\n")

    capture_io { Flare::SetupCommand.new.send(:add_gitignore_entries) }

    assert_equal "/tmp\nflare.sqlite3*\n", File.read(File.join(@dir, ".gitignore"))
  end

  def test_does_nothing_without_gitignore
    cmd = Flare::SetupCommand.new(force: false)
    out, = capture_io { cmd.send(:add_gitignore_entries) }
    assert_empty out
  end
end

class SetupCommandTokenPromptTest < Minitest::Test
  def test_closed_stdin_shows_the_token_instead_of_asking_forever
    output = answering("") { Flare::SetupCommand.new(force: false).send(:save_token, "tok_123") }

    assert_includes output, "FLARE_KEY=tok_123"
    assert_equal 1, output.scan("Choose (1/2/3)").size
    refute_includes output, "Invalid choice"
  end

  def test_an_invalid_choice_still_asks_again
    output = answering("9\n3\n") { Flare::SetupCommand.new(force: false).send(:save_token, "tok_123") }

    assert_includes output, "Invalid choice."
    assert_includes output, "FLARE_KEY=tok_123"
    assert_equal 2, output.scan("Choose (1/2/3)").size
  end

  private

  def answering(input)
    stdin = $stdin
    $stdin = StringIO.new(input)
    capture_io { yield }.first
  ensure
    $stdin = stdin
  end
end

class SetupCommandDotenvTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @original_dir = Dir.pwd
    Dir.chdir(@dir)
  end

  def teardown
    Dir.chdir(@original_dir)
    FileUtils.remove_entry(@dir)
  end

  def test_saves_token_to_existing_dotenv
    File.write(File.join(@dir, ".env"), "OTHER_VAR=hello\n")

    cmd = Flare::SetupCommand.new(force: false)
    capture_io { cmd.send(:save_to_dotenv, "test_token_123") }

    contents = File.read(File.join(@dir, ".env"))
    assert_includes contents, "FLARE_KEY=test_token_123"
    assert_includes contents, "OTHER_VAR=hello"
  end

  def test_replaces_existing_key_in_dotenv
    File.write(File.join(@dir, ".env"), "FLARE_KEY=old_token\n")

    cmd = Flare::SetupCommand.new(force: false)
    capture_io { cmd.send(:save_to_dotenv, "new_token") }

    contents = File.read(File.join(@dir, ".env"))
    assert_includes contents, "FLARE_KEY=new_token"
    refute_includes contents, "old_token"
  end

  def test_creates_dotenv_when_user_confirms
    cmd = Flare::SetupCommand.new(force: false)

    $stdin = StringIO.new("y\n")
    capture_io { cmd.send(:save_to_dotenv, "new_token") }
    $stdin = STDIN

    path = File.join(@dir, ".env")
    assert File.exist?(path)
    assert_equal "FLARE_KEY=new_token\n", File.read(path)
  end

  def test_prints_instructions_when_user_declines_dotenv_creation
    cmd = Flare::SetupCommand.new(force: false)

    $stdin = StringIO.new("n\n")
    out, = capture_io { cmd.send(:save_to_dotenv, "new_token") }
    $stdin = STDIN

    refute File.exist?(File.join(@dir, ".env"))
    assert_includes out, "FLARE_KEY=new_token"
    assert_includes out, "dotenv"
  end
end

class DoctorCommandTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @original_dir = Dir.pwd
    Dir.chdir(@dir)
    @original_env = ENV["FLARE_KEY"]
    @original_rails_env = ENV["RAILS_ENV"]
    ENV.delete("FLARE_KEY")
    ENV.delete("RAILS_ENV")
  end

  def teardown
    Dir.chdir(@original_dir)
    FileUtils.remove_entry(@dir)
    if @original_env
      ENV["FLARE_KEY"] = @original_env
    else
      ENV.delete("FLARE_KEY")
    end
    if @original_rails_env
      ENV["RAILS_ENV"] = @original_rails_env
    else
      ENV.delete("RAILS_ENV")
    end
  end

  def test_all_checks_pass
    # Set up everything correctly
    FileUtils.mkdir_p(File.join(@dir, "config/initializers"))
    File.write(File.join(@dir, "config/initializers/flare.rb"), "# config")
    File.write(File.join(@dir, ".env"), "FLARE_KEY=test_key\n")
    File.write(File.join(@dir, ".gitignore"), ".env\nflare.sqlite3*\n")
    FileUtils.mkdir_p(File.join(@dir, "db"))

    cmd = Flare::DoctorCommand.new
    out, = capture_io { cmd.run }

    assert_includes out, "Initializer exists"
    assert_includes out, "FLARE_KEY configured"
    assert_includes out, ".gitignore entries present"
    assert_includes out, "looks good"
  end

  # The rule a new Rails app's .gitignore has.
  def test_accepts_env_rule_from_a_new_rails_app
    File.write(File.join(@dir, ".env"), "FLARE_KEY=test_key\n")
    File.write(File.join(@dir, ".gitignore"), "/.env*\nflare.sqlite3*\n")

    out, = capture_io { Flare::DoctorCommand.new.run }

    assert_includes out, ".gitignore entries present"
    refute_includes out, ".gitignore missing"
  end

  def test_warns_when_env_exists_and_is_not_ignored
    File.write(File.join(@dir, ".env"), "FLARE_KEY=test_key\n")
    File.write(File.join(@dir, ".gitignore"), "/.environment\nflare.sqlite3*\n")

    out, = capture_io { Flare::DoctorCommand.new.run }

    assert_includes out, ".gitignore missing: .env"
  end

  def test_warns_when_a_later_rule_stops_ignoring_env
    File.write(File.join(@dir, ".env"), "FLARE_KEY=test_key\n")
    File.write(File.join(@dir, ".gitignore"), "/.env*\n!.env\nflare.sqlite3*\n")

    out, = capture_io { Flare::DoctorCommand.new.run }

    assert_includes out, ".gitignore missing: .env"
  end

  # Setup only adds .env when the key is in it, so it couldn't fix these.
  def test_does_not_ask_for_env_rule_without_an_env_file
    File.write(File.join(@dir, ".gitignore"), "flare.sqlite3*\n")

    out, = capture_io { Flare::DoctorCommand.new.run }

    assert_includes out, ".gitignore entries present"
  end

  def test_does_not_ask_for_env_rule_when_the_key_is_not_in_env
    File.write(File.join(@dir, ".env"), "OTHER_VAR=hello\n")
    File.write(File.join(@dir, ".gitignore"), "flare.sqlite3*\n")

    out, = capture_io { Flare::DoctorCommand.new.run }

    assert_includes out, ".gitignore entries present"
  end

  # The key was put in .env by hand, so setup skips auth. Doctor should agree
  # afterwards instead of sending people back to setup.
  def test_passes_after_setup_with_the_key_already_in_env
    File.write(File.join(@dir, ".env"), "FLARE_KEY=test_key\n")
    File.write(File.join(@dir, ".gitignore"), "/log\n")
    FileUtils.mkdir_p(File.join(@dir, "db"))

    setup_out, = capture_io { Flare::SetupCommand.new.run }
    out, = capture_io { Flare::DoctorCommand.new.run }

    assert_includes setup_out, "skipping auth"
    assert_includes out, ".gitignore entries present"
    assert_includes out, "Everything looks good!"
  end

  def test_missing_initializer
    File.write(File.join(@dir, ".env"), "FLARE_KEY=test_key\n")
    File.write(File.join(@dir, ".gitignore"), ".env\nflare.sqlite3*\n")

    cmd = Flare::DoctorCommand.new
    out, = capture_io { cmd.run }

    assert_includes out, "Initializer not found"
    assert_includes out, "flare setup"
  end

  def test_missing_key
    FileUtils.mkdir_p(File.join(@dir, "config/initializers"))
    File.write(File.join(@dir, "config/initializers/flare.rb"), "# config")
    File.write(File.join(@dir, ".gitignore"), ".env\nflare.sqlite3*\n")

    cmd = Flare::DoctorCommand.new
    out, = capture_io { cmd.run }

    assert_includes out, "FLARE_KEY not found"
  end

  def test_key_from_env_variable
    ENV["FLARE_KEY"] = "env_key"
    File.write(File.join(@dir, ".gitignore"), ".env\nflare.sqlite3*\n")
    FileUtils.mkdir_p(File.join(@dir, "config/initializers"))
    File.write(File.join(@dir, "config/initializers/flare.rb"), "# config")

    cmd = Flare::DoctorCommand.new
    out, = capture_io { cmd.run }

    assert_includes out, "FLARE_KEY configured"
  end

  def test_missing_gitignore_entries
    FileUtils.mkdir_p(File.join(@dir, "config/initializers"))
    File.write(File.join(@dir, "config/initializers/flare.rb"), "# config")
    File.write(File.join(@dir, ".env"), "FLARE_KEY=test_key\n")
    File.write(File.join(@dir, ".gitignore"), "# empty\n")

    cmd = Flare::DoctorCommand.new
    out, = capture_io { cmd.run }

    assert_includes out, ".gitignore missing"
  end

  def test_skips_database_check_in_production
    ENV["RAILS_ENV"] = "production"
    FileUtils.mkdir_p(File.join(@dir, "config/initializers"))
    File.write(File.join(@dir, "config/initializers/flare.rb"), "# config")
    File.write(File.join(@dir, ".env"), "FLARE_KEY=test_key\n")
    File.write(File.join(@dir, ".gitignore"), ".env\nflare.sqlite3*\n")

    cmd = Flare::DoctorCommand.new
    out, = capture_io { cmd.run }

    refute_includes out, "Database"
  end

  def test_skips_database_check_when_spans_disabled
    FileUtils.mkdir_p(File.join(@dir, "config/initializers"))
    File.write(File.join(@dir, "config/initializers/flare.rb"), <<~RUBY)
      Flare.configure do |config|
        config.spans_enabled = false
      end
    RUBY
    File.write(File.join(@dir, ".env"), "FLARE_KEY=test_key\n")
    File.write(File.join(@dir, ".gitignore"), ".env\nflare.sqlite3*\n")

    cmd = Flare::DoctorCommand.new
    out, = capture_io { cmd.run }

    refute_includes out, "Database"
  end

  def test_checks_database_in_development
    FileUtils.mkdir_p(File.join(@dir, "config/initializers"))
    File.write(File.join(@dir, "config/initializers/flare.rb"), "# config")
    File.write(File.join(@dir, ".env"), "FLARE_KEY=test_key\n")
    File.write(File.join(@dir, ".gitignore"), ".env\nflare.sqlite3*\n")
    FileUtils.mkdir_p(File.join(@dir, "db"))

    cmd = Flare::DoctorCommand.new
    out, = capture_io { cmd.run }

    assert_includes out, "Database"
  end
end

class StatusCommandTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @original_dir = Dir.pwd
    Dir.chdir(@dir)
    @original_env = ENV["FLARE_KEY"]
    @original_rails_env = ENV["RAILS_ENV"]
    @original_url = ENV["FLARE_URL"]
    ENV.delete("FLARE_KEY")
    ENV.delete("RAILS_ENV")
    ENV.delete("FLARE_URL")
  end

  def teardown
    Dir.chdir(@original_dir)
    FileUtils.remove_entry(@dir)
    if @original_env
      ENV["FLARE_KEY"] = @original_env
    else
      ENV.delete("FLARE_KEY")
    end
    if @original_rails_env
      ENV["RAILS_ENV"] = @original_rails_env
    else
      ENV.delete("RAILS_ENV")
    end
    if @original_url
      ENV["FLARE_URL"] = @original_url
    else
      ENV.delete("FLARE_URL")
    end
  end

  def test_shows_version
    cmd = Flare::StatusCommand.new
    out, = capture_io { cmd.run }
    assert_includes out, "Flare v#{Flare::VERSION}"
  end

  def test_shows_key_from_env
    ENV["FLARE_KEY"] = "env_key"
    cmd = Flare::StatusCommand.new
    out, = capture_io { cmd.run }
    assert_includes out, "set via ENV"
  end

  def test_shows_key_from_dotenv
    File.write(File.join(@dir, ".env"), "FLARE_KEY=test_key\n")
    cmd = Flare::StatusCommand.new
    out, = capture_io { cmd.run }
    assert_includes out, "set in .env"
  end

  def test_shows_key_not_configured
    cmd = Flare::StatusCommand.new
    out, = capture_io { cmd.run }
    assert_includes out, "not configured"
  end

  def test_shows_key_may_be_in_credentials
    FileUtils.mkdir_p(File.join(@dir, "config"))
    File.write(File.join(@dir, "config/credentials.yml.enc"), "encrypted")

    out, = capture_io { Flare::StatusCommand.new.run }

    assert_includes out, "may be in Rails credentials"
    refute_includes out, "not configured"
  end

  def test_shows_key_may_be_in_environment_credentials
    FileUtils.mkdir_p(File.join(@dir, "config/credentials"))
    File.write(File.join(@dir, "config/credentials/development.yml.enc"), "encrypted")

    out, = capture_io { Flare::StatusCommand.new.run }

    assert_includes out, "may be in Rails credentials"
  end

  def test_shows_file_statuses
    FileUtils.mkdir_p(File.join(@dir, "config/initializers"))
    File.write(File.join(@dir, "config/initializers/flare.rb"), "# config")

    cmd = Flare::StatusCommand.new
    out, = capture_io { cmd.run }

    assert_includes out, "Initializer"
    assert_includes out, "exists"
    assert_includes out, "not found"
  end

  def test_shows_custom_url
    ENV["FLARE_URL"] = "https://custom.example.com"
    cmd = Flare::StatusCommand.new
    out, = capture_io { cmd.run }
    assert_includes out, "https://custom.example.com"
  end

  def test_shows_default_url
    cmd = Flare::StatusCommand.new
    out, = capture_io { cmd.run }
    assert_includes out, "https://flare.am"
  end
end

class SetupCommandCallbackTest < Minitest::Test
  STATE = "expected-state"

  def setup
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @cmd = Flare::SetupCommand.new(force: false)
  end

  def teardown
    @server.close unless @server.closed?
  end

  def test_returns_code_from_valid_callback
    assert_equal "good-code", wait_for_code { send_request("/callback?state=#{STATE}&code=good-code") }
  end

  {
    wrong_state: "/callback?state=wrong&code=other",
    error_without_matching_state: "/callback?error=access_denied",
    missing_code: "/callback?state=#{STATE}",
    unparseable_path: "/callback?a=b|c"
  }.each do |name, path|
    define_method("test_keeps_waiting_after_#{name}") do
      code = wait_for_code do
        send_request(path)
        send_request("/callback?state=#{STATE}&code=good-code")
      end
      assert_equal "good-code", code
    end
  end

  def test_keeps_waiting_after_connection_that_sends_nothing
    code = wait_for_code do
      silent = TCPSocket.new("127.0.0.1", @port)
      begin
        response = send_request("/callback?state=#{STATE}&code=good-code")
        assert_includes response.to_s, "Authorized!"
      ensure
        silent.close
      end
    end
    assert_equal "good-code", code
  end

  def test_stops_on_error_callback_with_matching_state
    error = assert_raises(Flare::SetupCommand::AuthorizationDenied) do
      wait_for_code { send_request("/callback?state=#{STATE}&error=access_denied") }
    end
    assert_equal "access_denied", error.message
  end

  private

  def wait_for_code(timeout: 10)
    result = nil
    waiter = Thread.new { result = @cmd.send(:wait_for_callback, @server, STATE, timeout) }
    waiter.report_on_exception = false
    yield
    assert waiter.join(timeout + 2), "wait_for_callback did not return"
    result
  ensure
    waiter&.kill
  end

  def send_request(path)
    socket = TCPSocket.new("127.0.0.1", @port)
    socket.write("GET #{path} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    socket.read if IO.select([socket], nil, nil, 5)
  ensure
    socket&.close
  end
end
