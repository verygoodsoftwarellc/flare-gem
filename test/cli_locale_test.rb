# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "flare/cli/setup_command"

# A shell without a UTF-8 locale (LANG unset, or LC_ALL=C) makes Ruby read
# files as US-ASCII. The initializer flare setup writes, and many .env,
# .gitignore and AI client config files, aren't ASCII.
class CLILocaleTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @tmp = File.realpath(Dir.mktmpdir)
    @app = File.join(@tmp, "app")
    @home = File.join(@tmp, "home")
    FileUtils.mkdir_p([File.join(@app, "config", "initializers"), File.join(@home, "bin")])
    File.write(File.join(@app, "config", "initializers", "flare.rb"), Flare::SetupCommand::INITIALIZER_CONTENT)
    File.write(File.join(@app, ".gitignore"), "# Ignore bundler config — see bundler.io\n/.env*\n/db/flare.sqlite3*\n")
    File.write(File.join(@app, ".env"), "FLARE_KEY=abc\nGREETING=Café\n")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  # Plain ASCII .env and .gitignore, so only the initializer setup wrote isn't.
  def test_doctor_reads_the_setup_initializer_without_a_utf8_locale
    File.write(File.join(@app, ".env"), "FLARE_KEY=abc\n")
    File.write(File.join(@app, ".gitignore"), "/.env*\n/db/flare.sqlite3*\n")

    out, err, status = flare("doctor")

    assert status.success?, err
    assert_includes out, "Everything looks good!"
  end

  def test_doctor_reads_utf8_env_and_gitignore_without_a_utf8_locale
    out, err, status = flare("doctor")

    assert status.success?, err
    assert_includes out, "FLARE_KEY configured"
    assert_includes out, ".gitignore entries present"
  end

  def test_status_reads_utf8_files_without_a_utf8_locale
    out, err, status = flare("status")

    assert status.success?, err
    assert_includes out, "set in .env"
  end

  def test_connect_reads_a_utf8_claude_config_without_a_utf8_locale
    File.write(File.join(@home, ".claude.json"), %({"projects":{"/Users/josé/app":{}},"mcpServers":{}}))
    claude = File.join(@home, "bin", "claude")
    File.write(claude, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, claude)

    out, err, status = flare("connect")

    assert status.success?, err
    assert_includes out, "Connected Claude Code"
  end

  private

  def flare(*args)
    env = {
      "LC_ALL" => "C",
      "HOME" => @home, "PATH" => "#{@home}/bin:/usr/bin:/bin",
      "XDG_CONFIG_HOME" => nil, "CLAUDE_CONFIG_DIR" => nil, "FLARE_HOST" => nil,
      "FLARE_KEY" => nil, "RAILS_ENV" => nil
    }
    Open3.capture3(env, RbConfig.ruby, "-I", File.join(ROOT, "lib"), File.join(ROOT, "exe", "flare"), *args, chdir: @app)
  end
end
