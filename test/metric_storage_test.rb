# frozen_string_literal: true

require_relative "test_helper"
require "flare/metric_key"
require "flare/metric_storage"

class MetricStorageTest < Minitest::Test
  def setup
    @storage = Flare::MetricStorage.new
  end

  def test_empty_initially
    assert @storage.empty?
    assert_equal 0, @storage.size
  end

  def test_increment_creates_counter
    key = create_key("web", "rails", "UsersController", "show")
    @storage.increment(key, duration_ms: 100, error: false)

    refute @storage.empty?
    assert_equal 1, @storage.size
    assert_equal 1, @storage[key].count
  end

  def test_increment_same_key_accumulates
    key = create_key("web", "rails", "UsersController", "show")
    @storage.increment(key, duration_ms: 100, error: false)
    @storage.increment(key, duration_ms: 200, error: true)

    assert_equal 1, @storage.size
    assert_equal 2, @storage[key].count
    assert_equal 300, @storage[key].sum_ms
    assert_equal 1, @storage[key].error_count
  end

  def test_increment_different_keys
    key1 = create_key("web", "rails", "UsersController", "show")
    key2 = create_key("web", "rails", "UsersController", "index")

    @storage.increment(key1, duration_ms: 100, error: false)
    @storage.increment(key2, duration_ms: 200, error: false)

    assert_equal 2, @storage.size
    assert_equal 1, @storage[key1].count
    assert_equal 1, @storage[key2].count
  end

  def test_drain_returns_data_and_clears
    key1 = create_key("web", "rails", "UsersController", "show")
    key2 = create_key("db", "pg", "users", "SELECT")

    @storage.increment(key1, duration_ms: 100, error: false)
    @storage.increment(key2, duration_ms: 50, error: false)

    result = @storage.drain

    # Check result has the data
    assert_equal 2, result.size
    assert_equal({ count: 1, sum_ms: 100, error_count: 0 }, result[key1])
    assert_equal({ count: 1, sum_ms: 50, error_count: 0 }, result[key2])

    # Check storage is now empty
    assert @storage.empty?
  end

  def test_drain_returns_frozen_hash
    key = create_key("web", "rails", "UsersController", "show")
    @storage.increment(key, duration_ms: 100, error: false)

    result = @storage.drain

    assert result.frozen?
  end

  def test_thread_safe_increments
    key = create_key("web", "rails", "UsersController", "show")
    threads = []

    10.times do
      threads << Thread.new do
        100.times do
          @storage.increment(key, duration_ms: 1, error: false)
        end
      end
    end

    threads.each(&:join)

    assert_equal 1000, @storage[key].count
  end

  def test_thread_safe_different_keys
    threads = []

    10.times do |i|
      threads << Thread.new do
        key = create_key("web", "rails", "Controller#{i}", "action")
        100.times do
          @storage.increment(key, duration_ms: 1, error: false)
        end
      end
    end

    threads.each(&:join)

    assert_equal 10, @storage.size
  end

  private

  def create_key(namespace, service, target, operation)
    Flare::MetricKey.new(
      bucket: Time.now,
      namespace: namespace,
      service: service,
      target: target,
      operation: operation
    )
  end
end
