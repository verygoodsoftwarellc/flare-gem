# frozen_string_literal: true

module Flare
  # A small monotonic deadline shared by lifecycle operations. A nil timeout
  # represents an unbounded operation.
  class Deadline
    def initialize(timeout)
      @expires_at = monotonic_now + [timeout.to_f, 0].max unless timeout.nil?
    end

    def remaining
      return nil unless @expires_at

      [@expires_at - monotonic_now, 0].max
    end

    def expired?
      remaining == 0
    end

    private

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
