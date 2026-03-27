# frozen_string_literal: true

require "concurrent/atomic/atomic_fixnum"

module Flare
  # Thread-safe counter for metric aggregation.
  # Uses atomic operations for lock-free increments.
  #
  # Note: Durations are stored as integer milliseconds. Sub-millisecond
  # durations are truncated to 0. For very fast operations (e.g., cache hits),
  # the sum_ms may undercount actual time spent.
  class MetricCounter
    def initialize
      @count = Concurrent::AtomicFixnum.new(0)
      @sum_ms = Concurrent::AtomicFixnum.new(0)
      @error_count = Concurrent::AtomicFixnum.new(0)
    end

    def increment(duration_ms:, error: false)
      @count.increment
      @sum_ms.increment(duration_ms.to_i)
      @error_count.increment if error
    end

    def count
      @count.value
    end

    def sum_ms
      @sum_ms.value
    end

    def error_count
      @error_count.value
    end

    def to_h
      {
        count: @count.value,
        sum_ms: @sum_ms.value,
        error_count: @error_count.value
      }
    end
  end
end
