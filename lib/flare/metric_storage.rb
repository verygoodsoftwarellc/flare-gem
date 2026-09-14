# frozen_string_literal: true

require "concurrent/map"
require_relative "metric_counter"

module Flare
  # Thread-safe storage for metric aggregation.
  # Uses Concurrent::Map for lock-free reads and writes.
  class MetricStorage
    def initialize
      @storage = Concurrent::Map.new
      @pid = $$
    end

    def increment(key, duration_ms:, error: false)
      detect_forking
      counter = @storage.compute_if_absent(key) { MetricCounter.new }
      counter.increment(duration_ms: duration_ms, error: error)
    end

    def add(key, count:, sum_ms:, error_count: 0)
      detect_forking
      counter = @storage.compute_if_absent(key) { MetricCounter.new }
      counter.add(count: count, sum_ms: sum_ms, error_count: error_count)
    end

    # Atomically retrieves and clears all metrics.
    # Returns a frozen hash of MetricKey => counter data.
    def drain
      detect_forking
      result = {}
      @storage.keys.each do |key|
        counter = @storage.delete(key)
        result[key] = counter.to_h if counter
      end
      result.freeze
    end

    def size
      detect_forking
      @storage.size
    end

    def empty?
      detect_forking
      @storage.empty?
    end

    def [](key)
      detect_forking
      @storage[key]
    end

    def after_fork
      return if @pid == $$

      @pid = $$
      @storage = Concurrent::Map.new
    end

    private

    def detect_forking
      after_fork
    end
  end
end
