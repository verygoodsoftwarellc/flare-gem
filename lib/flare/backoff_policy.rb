# frozen_string_literal: true

module Flare
  # Exponential backoff with jitter for retry logic.
  # Based on Flipper's implementation.
  class BackoffPolicy
    # Default minimum timeout between intervals in milliseconds
    MIN_TIMEOUT_MS = 1_000  # 1 second

    # Default maximum timeout between intervals in milliseconds
    MAX_TIMEOUT_MS = 30_000 # 30 seconds

    # Value to multiply the current interval with for each retry attempt
    MULTIPLIER = 1.5

    # Randomization factor to create a range around the retry interval
    RANDOMIZATION_FACTOR = 0.5

    attr_reader :min_timeout_ms, :max_timeout_ms, :multiplier, :randomization_factor
    attr_reader :attempts

    def initialize(options = {})
      @min_timeout_ms = options.fetch(:min_timeout_ms) {
        ENV.fetch("FLARE_BACKOFF_MIN_TIMEOUT_MS", MIN_TIMEOUT_MS).to_i
      }
      @max_timeout_ms = options.fetch(:max_timeout_ms) {
        ENV.fetch("FLARE_BACKOFF_MAX_TIMEOUT_MS", MAX_TIMEOUT_MS).to_i
      }
      @multiplier = options.fetch(:multiplier) {
        ENV.fetch("FLARE_BACKOFF_MULTIPLIER", MULTIPLIER).to_f
      }
      @randomization_factor = options.fetch(:randomization_factor) {
        ENV.fetch("FLARE_BACKOFF_RANDOMIZATION_FACTOR", RANDOMIZATION_FACTOR).to_f
      }

      validate!
      @attempts = 0
    end

    # Returns the next backoff interval in milliseconds.
    def next_interval
      interval = @min_timeout_ms * (@multiplier**@attempts)
      interval = add_jitter(interval, @randomization_factor)

      @attempts += 1

      # Cap the interval to the max timeout
      result = [interval, @max_timeout_ms].min
      # Add small jitter even when maxed out
      result == @max_timeout_ms ? add_jitter(result, 0.05) : result
    end

    def reset
      @attempts = 0
    end

    private

    def validate!
      raise ArgumentError, ":min_timeout_ms must be >= 0" unless @min_timeout_ms >= 0
      raise ArgumentError, ":max_timeout_ms must be >= 0" unless @max_timeout_ms >= 0
      raise ArgumentError, ":min_timeout_ms must be <= :max_timeout_ms" unless @min_timeout_ms <= @max_timeout_ms
    end

    def add_jitter(base, randomization_factor)
      random_number = rand
      max_deviation = base * randomization_factor
      deviation = random_number * max_deviation

      random_number < 0.5 ? base - deviation : base + deviation
    end
  end
end
