# frozen_string_literal: true

require_relative "test_helper"
require "flare/revision"

class RevisionTest < Minitest::Test
  SHA = "0123456789abcdef0123456789abcdef01234567"

  def setup
    @root = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@root)
    Flare::Revision.reset!
  end

  def resolve(configured: nil, env: {})
    Flare::Revision.resolve(configured: configured, env: env, root: @root)
  end

  def test_configured_value_wins
    assert_equal "configured", resolve(configured: "configured", env: { "FLARE_REVISION" => "env", "GIT_SHA" => SHA })
  end

  def test_flare_revision_beats_platform_variables
    assert_equal "env", resolve(env: { "FLARE_REVISION" => "env", "HEROKU_SLUG_COMMIT" => SHA })
  end

  def test_platform_variables_in_order
    env = { "SOURCE_VERSION" => "source", "RENDER_GIT_COMMIT" => "render", "FLY_IMAGE_REF" => "fly" }
    assert_equal "render", resolve(env: env)
  end

  def test_blank_values_are_skipped
    assert_equal SHA, resolve(configured: "  ", env: { "FLARE_REVISION" => "", "GIT_SHA" => " #{SHA}\n" })
  end

  def test_revision_file_when_no_variables
    File.write(File.join(@root, "REVISION"), "#{SHA}\n")
    assert_equal SHA, resolve
  end

  def test_variables_beat_revision_file
    File.write(File.join(@root, "REVISION"), "file")
    assert_equal "kamal", resolve(env: { "KAMAL_VERSION" => "kamal" })
  end

  def test_git_head_when_repository_present
    skip "git not installed" unless system("git", "--version", out: File::NULL, err: File::NULL)

    git = ["git", "-C", @root, "-c", "user.name=t", "-c", "user.email=t@example.com"]
    system(*git, "init", "-q", out: File::NULL, err: File::NULL)
    system(*git, "commit", "-q", "--allow-empty", "-m", "first", out: File::NULL, err: File::NULL)
    expected = IO.popen(["git", "-C", @root, "rev-parse", "HEAD"], &:read).strip

    assert_equal expected, resolve
  end

  def test_nil_without_git_directory_or_file
    assert_nil resolve
  end

  def test_broken_git_directory_is_nil_not_an_error
    FileUtils.mkdir_p(File.join(@root, ".git"))
    assert_nil resolve
  end

  def test_truncates_to_64_characters
    assert_equal "a" * 64, resolve(env: { "GIT_SHA" => "a" * 100 })
  end

  def test_result_is_frozen
    assert_predicate resolve(env: { "GIT_SHA" => +"abc" }), :frozen?
  end

  def test_current_resolves_once
    Flare::Revision.reset!
    first = Flare::Revision.current
    Flare::Revision.stub(:resolve, "changed") do
      assert_same first, Flare::Revision.current
    end
  end
end
