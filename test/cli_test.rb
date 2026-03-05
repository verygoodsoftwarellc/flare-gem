# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "stringio"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "caboose/cli"
require "caboose/cli/output"
require "caboose/cli/setup_command"
require "caboose/cli/doctor_command"
require "caboose/cli/status_command"

class CLITest < Minitest::Test
  def test_version_command
    out, = capture_io { Caboose::CLI.start(["version"]) }
    assert_match(/caboose \d+\.\d+\.\d+/, out)
  end

  def test_version_flag
    out, = capture_io { Caboose::CLI.start(["--version"]) }
    assert_match(/caboose \d+\.\d+\.\d+/, out)
  end

  def test_help_command
    out, = capture_io { Caboose::CLI.start(["help"]) }
    assert_includes out, "Usage: caboose <command>"
    assert_includes out, "setup"
    assert_includes out, "doctor"
    assert_includes out, "status"
  end

  def test_help_with_no_args
    out, = capture_io { Caboose::CLI.start([]) }
    assert_includes out, "Usage: caboose <command>"
  end

  def test_unknown_command_exits
    assert_raises(SystemExit) do
      capture_io { Caboose::CLI.start(["bogus"]) }
    end
  end

  def test_commands_includes_doctor_and_status
    assert_includes Caboose::CLI::COMMANDS, "doctor"
    assert_includes Caboose::CLI::COMMANDS, "status"
  end
end

class CLIOutputTest < Minitest::Test
  include Caboose::CLI::Output

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
    cmd = Caboose::SetupCommand.new(force: false)
    capture_io { cmd.send(:create_initializer) }

    path = File.join(@dir, "config/initializers/caboose.rb")
    assert File.exist?(path)
    content = File.read(path)
    assert_includes content, "Caboose.configure"
    assert_includes content, "config.spans_enabled"
    assert_includes content, "config.metrics_enabled"
    assert_includes content, "config.metrics_flush_interval"
    assert_includes content, "Custom Instrumentation"
    assert_includes content, "app.geocoding"
  end

  def test_skips_existing_initializer_without_force
    FileUtils.mkdir_p(File.join(@dir, "config/initializers"))
    File.write(File.join(@dir, "config/initializers/caboose.rb"), "# existing")

    cmd = Caboose::SetupCommand.new(force: false)
    out, = capture_io { cmd.send(:create_initializer) }

    assert_equal "# existing", File.read(File.join(@dir, "config/initializers/caboose.rb"))
    assert_includes out, "already exists"
    assert_includes out, "--force"
  end

  def test_overwrites_existing_initializer_with_force
    FileUtils.mkdir_p(File.join(@dir, "config/initializers"))
    File.write(File.join(@dir, "config/initializers/caboose.rb"), "# existing")

    cmd = Caboose::SetupCommand.new(force: true)
    out, = capture_io { cmd.send(:create_initializer) }

    content = File.read(File.join(@dir, "config/initializers/caboose.rb"))
    refute_equal "# existing", content
    assert_includes content, "Caboose.configure"
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

    cmd = Caboose::SetupCommand.new(force: false)
    cmd.instance_variable_set(:@saved_to_dotenv, true)
    capture_io { cmd.send(:add_gitignore_entries) }

    contents = File.read(File.join(@dir, ".gitignore"))
    assert_includes contents, ".env"
    assert_includes contents, "/db/caboose.sqlite3*"
  end

  def test_skips_existing_gitignore_entries
    File.write(File.join(@dir, ".gitignore"), ".env\n/db/caboose.sqlite3*\n")

    cmd = Caboose::SetupCommand.new(force: false)
    out, = capture_io { cmd.send(:add_gitignore_entries) }

    refute_includes out, "Added"
  end

  def test_does_nothing_without_gitignore
    cmd = Caboose::SetupCommand.new(force: false)
    out, = capture_io { cmd.send(:add_gitignore_entries) }
    assert_empty out
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

    cmd = Caboose::SetupCommand.new(force: false)
    capture_io { cmd.send(:save_to_dotenv, "test_token_123") }

    contents = File.read(File.join(@dir, ".env"))
    assert_includes contents, "CABOOSE_KEY=test_token_123"
    assert_includes contents, "OTHER_VAR=hello"
  end

  def test_replaces_existing_key_in_dotenv
    File.write(File.join(@dir, ".env"), "CABOOSE_KEY=old_token\n")

    cmd = Caboose::SetupCommand.new(force: false)
    capture_io { cmd.send(:save_to_dotenv, "new_token") }

    contents = File.read(File.join(@dir, ".env"))
    assert_includes contents, "CABOOSE_KEY=new_token"
    refute_includes contents, "old_token"
  end

  def test_creates_dotenv_when_user_confirms
    cmd = Caboose::SetupCommand.new(force: false)

    $stdin = StringIO.new("y\n")
    capture_io { cmd.send(:save_to_dotenv, "new_token") }
    $stdin = STDIN

    path = File.join(@dir, ".env")
    assert File.exist?(path)
    assert_equal "CABOOSE_KEY=new_token\n", File.read(path)
  end

  def test_prints_instructions_when_user_declines_dotenv_creation
    cmd = Caboose::SetupCommand.new(force: false)

    $stdin = StringIO.new("n\n")
    out, = capture_io { cmd.send(:save_to_dotenv, "new_token") }
    $stdin = STDIN

    refute File.exist?(File.join(@dir, ".env"))
    assert_includes out, "CABOOSE_KEY=new_token"
    assert_includes out, "dotenv"
  end
end

class DoctorCommandTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @original_dir = Dir.pwd
    Dir.chdir(@dir)
    @original_env = ENV["CABOOSE_KEY"]
    @original_rails_env = ENV["RAILS_ENV"]
    ENV.delete("CABOOSE_KEY")
    ENV.delete("RAILS_ENV")
  end

  def teardown
    Dir.chdir(@original_dir)
    FileUtils.remove_entry(@dir)
    if @original_env
      ENV["CABOOSE_KEY"] = @original_env
    else
      ENV.delete("CABOOSE_KEY")
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
    File.write(File.join(@dir, "config/initializers/caboose.rb"), "# config")
    File.write(File.join(@dir, ".env"), "CABOOSE_KEY=test_key\n")
    File.write(File.join(@dir, ".gitignore"), ".env\n/db/caboose.sqlite3*\n")
    FileUtils.mkdir_p(File.join(@dir, "db"))

    cmd = Caboose::DoctorCommand.new
    out, = capture_io { cmd.run }

    assert_includes out, "Initializer exists"
    assert_includes out, "CABOOSE_KEY configured"
    assert_includes out, ".gitignore entries present"
    assert_includes out, "looks good"
  end

  def test_missing_initializer
    File.write(File.join(@dir, ".env"), "CABOOSE_KEY=test_key\n")
    File.write(File.join(@dir, ".gitignore"), ".env\n/db/caboose.sqlite3*\n")

    cmd = Caboose::DoctorCommand.new
    out, = capture_io { cmd.run }

    assert_includes out, "Initializer not found"
    assert_includes out, "caboose setup"
  end

  def test_missing_key
    FileUtils.mkdir_p(File.join(@dir, "config/initializers"))
    File.write(File.join(@dir, "config/initializers/caboose.rb"), "# config")
    File.write(File.join(@dir, ".gitignore"), ".env\n/db/caboose.sqlite3*\n")

    cmd = Caboose::DoctorCommand.new
    out, = capture_io { cmd.run }

    assert_includes out, "CABOOSE_KEY not found"
  end

  def test_key_from_env_variable
    ENV["CABOOSE_KEY"] = "env_key"
    File.write(File.join(@dir, ".gitignore"), ".env\n/db/caboose.sqlite3*\n")
    FileUtils.mkdir_p(File.join(@dir, "config/initializers"))
    File.write(File.join(@dir, "config/initializers/caboose.rb"), "# config")

    cmd = Caboose::DoctorCommand.new
    out, = capture_io { cmd.run }

    assert_includes out, "CABOOSE_KEY configured"
  end

  def test_missing_gitignore_entries
    FileUtils.mkdir_p(File.join(@dir, "config/initializers"))
    File.write(File.join(@dir, "config/initializers/caboose.rb"), "# config")
    File.write(File.join(@dir, ".env"), "CABOOSE_KEY=test_key\n")
    File.write(File.join(@dir, ".gitignore"), "# empty\n")

    cmd = Caboose::DoctorCommand.new
    out, = capture_io { cmd.run }

    assert_includes out, ".gitignore missing"
  end

  def test_skips_database_check_in_production
    ENV["RAILS_ENV"] = "production"
    FileUtils.mkdir_p(File.join(@dir, "config/initializers"))
    File.write(File.join(@dir, "config/initializers/caboose.rb"), "# config")
    File.write(File.join(@dir, ".env"), "CABOOSE_KEY=test_key\n")
    File.write(File.join(@dir, ".gitignore"), ".env\n/db/caboose.sqlite3*\n")

    cmd = Caboose::DoctorCommand.new
    out, = capture_io { cmd.run }

    refute_includes out, "Database"
  end

  def test_skips_database_check_when_spans_disabled
    FileUtils.mkdir_p(File.join(@dir, "config/initializers"))
    File.write(File.join(@dir, "config/initializers/caboose.rb"), <<~RUBY)
      Caboose.configure do |config|
        config.spans_enabled = false
      end
    RUBY
    File.write(File.join(@dir, ".env"), "CABOOSE_KEY=test_key\n")
    File.write(File.join(@dir, ".gitignore"), ".env\n/db/caboose.sqlite3*\n")

    cmd = Caboose::DoctorCommand.new
    out, = capture_io { cmd.run }

    refute_includes out, "Database"
  end

  def test_checks_database_in_development
    FileUtils.mkdir_p(File.join(@dir, "config/initializers"))
    File.write(File.join(@dir, "config/initializers/caboose.rb"), "# config")
    File.write(File.join(@dir, ".env"), "CABOOSE_KEY=test_key\n")
    File.write(File.join(@dir, ".gitignore"), ".env\n/db/caboose.sqlite3*\n")
    FileUtils.mkdir_p(File.join(@dir, "db"))

    cmd = Caboose::DoctorCommand.new
    out, = capture_io { cmd.run }

    assert_includes out, "Database"
  end
end

class StatusCommandTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @original_dir = Dir.pwd
    Dir.chdir(@dir)
    @original_env = ENV["CABOOSE_KEY"]
    @original_rails_env = ENV["RAILS_ENV"]
    @original_url = ENV["CABOOSE_URL"]
    ENV.delete("CABOOSE_KEY")
    ENV.delete("RAILS_ENV")
    ENV.delete("CABOOSE_URL")
  end

  def teardown
    Dir.chdir(@original_dir)
    FileUtils.remove_entry(@dir)
    if @original_env
      ENV["CABOOSE_KEY"] = @original_env
    else
      ENV.delete("CABOOSE_KEY")
    end
    if @original_rails_env
      ENV["RAILS_ENV"] = @original_rails_env
    else
      ENV.delete("RAILS_ENV")
    end
    if @original_url
      ENV["CABOOSE_URL"] = @original_url
    else
      ENV.delete("CABOOSE_URL")
    end
  end

  def test_shows_version
    cmd = Caboose::StatusCommand.new
    out, = capture_io { cmd.run }
    assert_includes out, "Caboose v#{Caboose::VERSION}"
  end

  def test_shows_key_from_env
    ENV["CABOOSE_KEY"] = "env_key"
    cmd = Caboose::StatusCommand.new
    out, = capture_io { cmd.run }
    assert_includes out, "set via ENV"
  end

  def test_shows_key_from_dotenv
    File.write(File.join(@dir, ".env"), "CABOOSE_KEY=test_key\n")
    cmd = Caboose::StatusCommand.new
    out, = capture_io { cmd.run }
    assert_includes out, "set in .env"
  end

  def test_shows_key_not_configured
    cmd = Caboose::StatusCommand.new
    out, = capture_io { cmd.run }
    assert_includes out, "not configured"
  end

  def test_shows_file_statuses
    FileUtils.mkdir_p(File.join(@dir, "config/initializers"))
    File.write(File.join(@dir, "config/initializers/caboose.rb"), "# config")

    cmd = Caboose::StatusCommand.new
    out, = capture_io { cmd.run }

    assert_includes out, "Initializer"
    assert_includes out, "exists"
    assert_includes out, "not found"
  end

  def test_shows_custom_url
    ENV["CABOOSE_URL"] = "https://custom.example.com"
    cmd = Caboose::StatusCommand.new
    out, = capture_io { cmd.run }
    assert_includes out, "https://custom.example.com"
  end

  def test_shows_default_url
    cmd = Caboose::StatusCommand.new
    out, = capture_io { cmd.run }
    assert_includes out, "https://caboose.dev"
  end
end
