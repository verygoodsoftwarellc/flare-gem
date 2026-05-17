# frozen_string_literal: true

require_relative "test_helper"
require "flare/upload_url_pool"

class UploadUrlPoolTest < Minitest::Test
  def setup
    @pool = Flare::UploadUrlPool.new
  end

  def test_replace_populates_the_pool
    @pool.replace([entry("u1"), entry("u2")])
    assert_equal 2, @pool.size
  end

  def test_checkout_returns_entries_in_order_and_drains_the_pool
    @pool.replace([entry("u1"), entry("u2")])

    first = @pool.checkout
    second = @pool.checkout
    third = @pool.checkout

    assert_equal "u1", first[:upload_id]
    assert_equal "u2", second[:upload_id]
    assert_nil third
    assert @pool.empty?
  end

  def test_checkout_skips_expired_entries
    @pool.replace([
      entry("expired", expires_at: Time.now - 60),
      entry("fresh",   expires_at: Time.now + 60)
    ])

    assert_equal "fresh", @pool.checkout[:upload_id]
    assert_equal 1, @pool.expired_count.value
  end

  def test_empty_count_increments_on_empty_checkout
    assert_nil @pool.checkout
    assert_equal 1, @pool.empty_count.value
  end

  def test_replace_with_mixed_string_and_symbol_keys
    @pool.replace([{ "upload_id" => "u1", "key" => "k1", "put_url" => "https://x", "expires_at" => (Time.now + 60).iso8601 }])
    entry = @pool.checkout
    assert_equal "u1", entry[:upload_id]
  end

  def test_replace_drops_malformed_entries
    @pool.replace([
      entry("ok"),
      { upload_id: "missing-url" },
      "not a hash",
      nil
    ])
    assert_equal 1, @pool.size
  end

  def test_sweep_drops_expired_entries
    @pool.replace([
      entry("expired", expires_at: Time.now - 60),
      entry("fresh",   expires_at: Time.now + 60)
    ])

    dropped = @pool.sweep

    assert_equal 1, dropped
    assert_equal 1, @pool.size
    assert_equal "fresh", @pool.checkout[:upload_id]
  end

  def test_after_fork_clears_the_pool
    @pool.replace([entry("u1"), entry("u2")])
    @pool.after_fork

    assert @pool.empty?
  end

  def test_replace_atomically_swaps
    @pool.replace([entry("old1"), entry("old2")])
    @pool.replace([entry("new1")])

    assert_equal "new1", @pool.checkout[:upload_id]
    assert_nil @pool.checkout
  end

  private

  def entry(upload_id, expires_at: Time.now + 60)
    {
      upload_id:  upload_id,
      key:        "incoming/env=1/#{upload_id}.json.gz",
      put_url:    "https://r2/put/#{upload_id}",
      expires_at: expires_at
    }
  end
end
