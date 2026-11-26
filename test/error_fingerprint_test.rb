# frozen_string_literal: true

require_relative "test_helper"
require "flare/error_fingerprint"

class ErrorFingerprintTest < Minitest::Test
  ROOT = "/srv/app/releases/20261125/"
  GEMS = "/usr/local/bundle/ruby/3.4.0/gems"

  def fingerprint(class_name, backtrace)
    error = Class.new(StandardError).new("boom")
    error.set_backtrace(backtrace)
    frames = Flare::ErrorFingerprint.frames(error, root: ROOT)
    Flare::ErrorFingerprint.fingerprint(class_name, frames)
  end

  def test_fingerprint_is_16_lowercase_hex
    assert_match(/\A[0-9a-f]{16}\z/, fingerprint("RuntimeError", ["#{ROOT}app/models/user.rb:10:in `save'"]))
  end

  def test_same_bug_across_line_changes_keeps_its_fingerprint
    before = fingerprint("NoMethodError", [
      "#{ROOT}app/models/user.rb:10:in `full_name'",
      "#{GEMS}/activesupport-7.2.3/lib/active_support/callbacks.rb:100:in `run'",
      "#{ROOT}app/controllers/users_controller.rb:20:in `show'"
    ])
    after = fingerprint("NoMethodError", [
      "#{ROOT}app/models/user.rb:42:in `full_name'",
      "#{GEMS}/activesupport-7.2.3/lib/active_support/callbacks.rb:117:in `run'",
      "#{ROOT}app/controllers/users_controller.rb:31:in `show'"
    ])

    assert_equal before, after
  end

  def test_different_class_or_method_changes_the_fingerprint
    base = fingerprint("NoMethodError", ["#{ROOT}app/models/user.rb:10:in `full_name'"])

    refute_equal base, fingerprint("ArgumentError", ["#{ROOT}app/models/user.rb:10:in `full_name'"])
    refute_equal base, fingerprint("NoMethodError", ["#{ROOT}app/models/user.rb:10:in `email'"])
    refute_equal base, fingerprint("NoMethodError", ["#{ROOT}app/models/account.rb:10:in `full_name'"])
  end

  def test_ruby_34_labels_match_older_labels
    old = fingerprint("RuntimeError", [
      "#{ROOT}app/models/user.rb:10:in `block (2 levels) in save'",
      "#{ROOT}app/models/user.rb:8:in `save'"
    ])
    new = fingerprint("RuntimeError", [
      "#{ROOT}app/models/user.rb:10:in 'block (2 levels) in User#save'",
      "#{ROOT}app/models/user.rb:8:in 'User#save'"
    ])

    assert_equal old, new
  end

  def test_generated_template_methods_and_ids_are_stripped
    a = fingerprint("ActionView::Template::Error", [
      "#{ROOT}app/views/users/show.html.erb:3:in `_app_views_users_show_html_erb___1234_5678'"
    ])
    b = fingerprint("ActionView::Template::Error", [
      "#{ROOT}app/views/users/show.html.erb:3:in `_app_views_users_show_html_erb___9999_1111'"
    ])

    assert_equal a, b
  end

  def test_only_top_app_frames_count
    shared = [
      "#{ROOT}app/models/user.rb:10:in `a'",
      "#{ROOT}app/models/user.rb:11:in `b'",
      "#{ROOT}app/models/user.rb:12:in `c'"
    ]

    assert_equal fingerprint("E", shared + ["#{ROOT}app/jobs/one.rb:1:in `perform'"]),
                 fingerprint("E", shared + ["#{ROOT}app/jobs/two.rb:1:in `perform'"])
  end

  def test_wrapping_code_in_a_block_keeps_the_fingerprint
    plain = fingerprint("E", [
      "#{ROOT}app/models/user.rb:10:in `save'",
      "#{ROOT}app/controllers/users_controller.rb:5:in `update'"
    ])
    with_block = fingerprint("E", [
      "#{ROOT}app/models/user.rb:11:in `block in save'",
      "/usr/local/lib/ruby/3.4.0/set.rb:1:in `each'",
      "#{ROOT}app/models/user.rb:10:in `save'",
      "#{ROOT}app/controllers/users_controller.rb:5:in `update'"
    ])

    assert_equal plain, with_block
  end

  def test_without_app_frames_gem_frames_count_without_versions
    a = fingerprint("Redis::TimeoutError", ["#{GEMS}/redis-5.0.1/lib/redis/client.rb:10:in `call'"])
    b = fingerprint("Redis::TimeoutError", ["/home/deploy/.gem/ruby/3.4.0/gems/redis-5.2.0/lib/redis/client.rb:99:in `call'"])

    assert_equal a, b
  end

  def test_vendored_gems_inside_the_root_are_not_app_frames
    error = StandardError.new
    error.set_backtrace([
      "#{ROOT}vendor/bundle/ruby/3.4.0/gems/rack-3.0.0/lib/rack.rb:1:in `call'",
      "#{ROOT}app/models/user.rb:1:in `save'"
    ])
    frames = Flare::ErrorFingerprint.frames(error, root: ROOT)

    assert_equal [false, true], frames.map(&:app)
    assert_equal "rack-3.0.0/lib/rack.rb", frames.first.file
    assert_equal "app/models/user.rb", frames.last.file
  end

  def test_real_backtrace_locations_are_used
    error = begin
      raise ArgumentError, "x"
    rescue => e
      e
    end
    frames = Flare::ErrorFingerprint.frames(error, root: "#{File.dirname(__dir__)}/")

    assert_equal "test/error_fingerprint_test.rb", frames.first.file
    assert frames.first.app
    assert_kind_of Integer, frames.first.line
  end
end
