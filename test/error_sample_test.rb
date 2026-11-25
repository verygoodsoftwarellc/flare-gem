# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "zlib"
require "flare/error_sample"

class ErrorSampleTest < Minitest::Test
  Frame = Flare::ErrorFingerprint::Frame

  def test_scrub_message_masks_values
    assert_equal "Couldn't find User with ?=?", Flare::ErrorSample.scrub_message("Couldn't find User with 'id'=123")
    assert_equal "no account for ?", Flare::ErrorSample.scrub_message("no account for jane.doe+x@example.com")
    assert_equal "token ? expired at ?", Flare::ErrorSample.scrub_message(%(token "abc def" expired at 1700000000))
    assert_equal "upload ? missing", Flare::ErrorSample.scrub_message("upload 550e8400-e29b-41d4-a716-446655440000 missing")
    assert_equal "digest ? bad", Flare::ErrorSample.scrub_message("digest 9f86d081884c7d65 bad")
  end

  def test_scrub_message_masks_unterminated_and_assigned_values
    assert_equal "bad value ?", Flare::ErrorSample.scrub_message("bad value 'hunter2 and more")
    assert_equal "Key (email)=? already exists.", Flare::ErrorSample.scrub_message("Key (email)=(jane smith) already exists.")
    assert_equal "login failed token=? for user", Flare::ErrorSample.scrub_message("login failed token=abcXYZ for user")

    assert_equal "bad value ?", Flare::ErrorSample.scrub_message("bad value 'hunter2\\")
    assert_equal "Key (a, b)=? already exists.", Flare::ErrorSample.scrub_message("Key (a, b)=(1, x) y) already exists.")
    assert_equal "password =? rejected", Flare::ErrorSample.scrub_message("password = hunter2 rejected")
    assert_equal "password =? rejected", Flare::ErrorSample.scrub_message(%(password = "hunter two" rejected))
    assert_equal "Key (a)=? already exists.", Flare::ErrorSample.scrub_message("Key (a)=(first line\nsecret) already exists.")
    assert_equal "Key (a)=?", Flare::ErrorSample.scrub_message("Key (a)=(first line\nsecret")

    cut = Flare::ErrorSample.scrub_message("#{"x" * 4_000} 'secret #{"y" * 200}' tail")
    refute_includes cut, "y"
  end

  def test_param_names_mask_keys_that_are_not_identifiers
    names = Flare::ErrorSample.param_names(
      "jane@example.com" => "1", "12345" => "2", "9f86d081884c7d65" => "3",
      "user" => { "has space" => "x", "ok_key" => "y" }
    )
    assert_equal ["?", "?", "?", "user[?]", "user[ok_key]"], names
  end

  def test_scrub_message_keeps_method_and_constant_names
    assert_equal "undefined method 'full_name' for nil", Flare::ErrorSample.scrub_message("undefined method 'full_name' for nil")
    assert_equal "undefined method `full_name' for nil:NilClass", Flare::ErrorSample.scrub_message("undefined method `full_name' for nil:NilClass")
  end

  def test_scrub_message_cuts_long_messages
    message = Flare::ErrorSample.scrub_message("x" * 10_000)
    assert_operator message.bytesize, :<=, Flare::ErrorSample::MAX_MESSAGE_BYTES + 4
  end

  def test_trim_frames_keeps_every_app_frame_and_cuts_gem_frames_from_the_middle
    frames = Array.new(300) { |i| Frame.new(file: "f#{i}.rb", line: i, method: "m", app: (i % 10).zero?) }
    kept, omitted = Flare::ErrorSample.trim_frames(frames)

    assert_equal 200, kept.size
    assert_equal 100, omitted
    assert_equal 30, kept.count(&:app)
    assert_equal frames.first, kept.first
    assert_equal frames.last, kept.last
    assert_equal kept, kept.sort_by(&:line)
    # The cut is in the middle of the gem frames.
    refute_includes kept.map(&:line), 151
  end

  def test_trim_frames_with_more_app_frames_than_room
    frames = Array.new(250) { |i| Frame.new(file: "f#{i}.rb", line: i, method: "m", app: true) }
    kept, omitted = Flare::ErrorSample.trim_frames(frames)

    assert_equal 200, kept.size
    assert_equal 50, omitted
    assert_equal [0, 249], [kept.first.line, kept.last.line]
  end

  def test_param_names_are_names_only
    names = Flare::ErrorSample.param_names(
      "controller" => "users", "action" => "update", "id" => "5",
      "user" => { "email" => "a@b.c", "tags" => ["x"], "address" => { "zip" => "12345" } }
    )

    assert_equal ["id", "user[email]", "user[tags][]", "user[address][zip]"], names
  end

  def test_build_produces_json_with_the_sample_fields
    json = build(message: "Couldn't find User with 'id'=123")
    sample = JSON.parse(json)

    assert_equal "abcdefabcdefabcd", sample["fingerprint"]
    assert_equal "RuntimeError", sample["class"]
    assert_equal "Couldn't find User with ?=?", sample["message"]
    assert_equal false, sample["handled"]
    assert_equal "UsersController#show", sample["operation"]
    assert_equal "sha1", sample["revision"]
    assert_equal ["id"], sample["params"]
    assert_equal ["app/models/user.rb:save"], sample["frames"]
    assert_equal({ "file" => "app/models/user.rb", "line" => 10, "method" => "save", "app" => true }, sample["backtrace"].first)
  end

  def test_build_stays_under_the_size_cap
    huge_frames = Array.new(200) { |i| Frame.new(file: "gems/#{"x" * 3_000}/f#{i}.rb", line: i, method: "m", app: i.zero?) }
    json = build(message: "y" * 100_000, frames: huge_frames)

    assert_operator json.bytesize, :<=, Flare::ErrorSample::MAX_BYTES
    sample = JSON.parse(json)
    assert sample["backtrace"].first["app"]
    assert_operator sample["omitted_frames"], :>, 0
  end

  def test_build_returns_nil_when_it_cannot_fit
    frames = Array.new(20) { |i| Frame.new(file: "a" * 30_000, line: i, method: "m", app: true) }
    assert_nil build(frames: frames)
  end

  def test_gzip_round_trips
    json = build
    assert_equal json, Zlib.gunzip(Flare::ErrorSample.gzip(json))
  end

  private

  def build(message: "boom", frames: nil)
    frames ||= [Frame.new(file: "app/models/user.rb", line: 10, method: "save", app: true),
                Frame.new(file: "rack-3.0.0/lib/rack.rb", line: 1, method: "call", app: false)]
    Flare::ErrorSample.build(
      exception: RuntimeError.new(message), class_name: "RuntimeError", fingerprint: "abcdefabcdefabcd",
      frames: frames, handled: false, operation: "UsersController#show", occurred_at: Time.utc(2026, 11, 25),
      revision: "sha1", host: "web-1", params: ["id"]
    )
  end
end
