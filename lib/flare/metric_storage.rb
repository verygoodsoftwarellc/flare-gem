# frozen_string_literal: true

require "concurrent/map"
require_relative "metric_counter"

module Flare
  # Thread-safe storage for metric aggregation.
  # Uses Concurrent::Map for lock-free reads and writes.
  class MetricStorage
    def initialize
      @storage = Concurrent::Map.new
    end

    def increment(key, duration_ms:, error: false, slow: false)
      counter = @storage.compute_if_absent(key) { MetricCounter.new }
      counter.increment(duration_ms: duration_ms, error: error, slow: slow)
    end

    def add(key, count:, sum_ms:, error_count: 0, slow_count: 0)
      counter = @storage.compute_if_absent(key) { MetricCounter.new }
      counter.add(count: count, sum_ms: sum_ms, error_count: error_count, slow_count: slow_count)
    end

    # Atomically retrieves and clears all metrics.
    # Returns a frozen hash of MetricKey => counter data.
    def drain
      result = {}
      @storage.keys.each do |key|
        counter = @storage.delete(key)
        result[key] = counter.to_h if counter
      end
      result.freeze
    end

    def size
      @storage.size
    end

    def empty?
      @storage.empty?
    end

    def [](key)
      @storage[key]
    end
  end
end
