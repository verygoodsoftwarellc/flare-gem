# frozen_string_literal: true

require_relative "test_helper"
require "flare/metric_counter"

class MetricCounterTest < Minitest::Test
  def test_initial_values
    counter = Flare::MetricCounter.new

    assert_equal 0, counter.count
    assert_equal 0, counter.sum_ms
    assert_equal 0, counter.error_count
  end

  def test_increment_without_error
    counter = Flare::MetricCounter.new
    counter.increment(duration_ms: 100, error: false)

    assert_equal 1, counter.count
    assert_equal 100, counter.sum_ms
    assert_equal 0, counter.error_count
  end

  def test_increment_with_error
    counter = Flare::MetricCounter.new
    counter.increment(duration_ms: 50, error: true)

    assert_equal 1, counter.count
    assert_equal 50, counter.sum_ms
    assert_equal 1, counter.error_count
  end

  def test_multiple_increments
    counter = Flare::MetricCounter.new
    counter.increment(duration_ms: 100, error: false)
    counter.increment(duration_ms: 200, error: true)
    counter.increment(duration_ms: 150, error: false)

    assert_equal 3, counter.count
    assert_equal 450, counter.sum_ms
    assert_equal 1, counter.error_count
  end

  def test_to_h
    counter = Flare::MetricCounter.new
    counter.increment(duration_ms: 100, error: false)
    counter.increment(duration_ms: 200, error: true)

    expected = {
      count: 2,
      sum_ms: 300,
      error_count: 1
    }

    assert_equal expected, counter.to_h
  end

  def test_thread_safety
    counter = Flare::MetricCounter.new
    threads = []

    10.times do
      threads << Thread.new do
        100.times do
          counter.increment(duration_ms: 1, error: false)
        end
      end
    end

    threads.each(&:join)

    assert_equal 1000, counter.count
    assert_equal 1000, counter.sum_ms
  end
end
