# frozen_string_literal: true

require_relative "test_helper"
require "flare/revision"
require "minitest/mock"

class RevisionTest < Minitest::Test
  SHA = "0123456789abcdef0123456789abcdef01234567"

  def setup
    @root = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def resolve(configured: nil, env: {})
    Flare::Revision.resolve(configured, env: env, root: @root)
  end

  def test_configured_value_wins
    assert_equal "configured", resolve(configured: "configured", env: { "HEROKU_SLUG_COMMIT" => SHA })
  end

  def test_platform_variables_in_order
    env = { "SOURCE_VERSION" => "source", "RENDER_GIT_COMMIT" => "render", "FLY_IMAGE_REF" => "fly" }
    assert_equal "render", resolve(env: env)
  end

  def test_fly_image_ref_uses_the_image_tag
    assert_equal SHA, resolve(env: { "FLY_IMAGE_REF" => "registry.fly.io/my-app:#{SHA}" })
    assert_equal "deployment-01JABC", resolve(env: { "FLY_IMAGE_REF" => "registry.fly.io/my-app:deployment-01JABC@sha256:#{"f" * 64}" })
  end

  def test_fly_image_ref_without_a_tag_falls_through
    assert_equal "git", resolve(env: { "FLY_IMAGE_REF" => "registry.fly.io/my-app", "GIT_SHA" => "git" })
  end

  def test_blank_values_are_skipped
    assert_equal SHA, resolve(configured: "  ", env: { "HEROKU_SLUG_COMMIT" => "", "GIT_SHA" => " #{SHA}\n" })
  end

  def test_revision_file_when_no_variables
    File.write(File.join(@root, "REVISION"), "#{SHA}\n")
    assert_equal SHA, resolve
  end

  def test_only_the_first_line_is_used
    File.write(File.join(@root, "REVISION"), "\n#{SHA}\nbuilt by ci\n")
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

  def test_configuration_defaults_to_flare_revision
    with_env("FLARE_REVISION" => "from-env") do
      assert_equal "from-env", Flare::Configuration.new.revision
    end
  end

  def test_configuration_resolves_once
    config = Flare::Configuration.new
    config.revision = nil
    calls = 0
    Flare::Revision.stub(:resolve, ->(_) { calls += 1; nil }) do
      2.times { assert_nil config.revision }
    end
    assert_equal 1, calls
  end

  # Regression: ISSUE-001 — a reader racing the first resolve got nil
  # Found by /qa on 2026-11-11
  # Report: .gstack/qa-reports/run-20261111T164002Z/qa-report-flare-gem-revision-2026-11-11.md
  def test_concurrent_first_reads_all_get_the_resolved_value
    config = Flare::Configuration.new
    config.revision = nil
    slow = ->(_) { sleep 0.05; "resolved" }
    Flare::Revision.stub(:resolve, slow) do
      values = 4.times.map { Thread.new { config.revision } }.map(&:value)
      assert_equal ["resolved"], values.uniq
    end
  end

  def test_setting_the_revision_after_a_read_takes_effect
    config = Flare::Configuration.new
    config.revision
    config.revision = "later"
    assert_equal "later", config.revision
  end

  private

  def with_env(values)
    saved = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end
end
