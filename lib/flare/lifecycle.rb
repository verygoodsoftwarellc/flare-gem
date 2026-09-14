# frozen_string_literal: true

require "opentelemetry/sdk"

require_relative "deadline"

module Flare
  module Lifecycle
    # Flush all trace processors and the separate aggregated metric pipeline
    # using one monotonic timeout budget. This is safe to call from lifecycle
    # hooks for short-lived and fork-per-job workers.
    def force_flush(timeout: nil)
      deadline = Deadline.new(timeout)
      results = []

      results << tracer_provider_for_flush.force_flush(timeout: deadline.remaining)
      return OpenTelemetry::SDK::Trace::Export::TIMEOUT if deadline.expired?

      flusher = metric_flusher_for_flush
      results << flusher.force_flush(timeout: deadline.remaining) if flusher
      return OpenTelemetry::SDK::Trace::Export::TIMEOUT if deadline.expired?

      results.max || OpenTelemetry::SDK::Trace::Export::SUCCESS
    rescue => e
      warn "[Flare] Telemetry flush error: #{e.message}"
      OpenTelemetry::SDK::Trace::Export::FAILURE
    end

    def tracer_provider_for_flush
      OpenTelemetry.tracer_provider
    end

    def metric_flusher_for_flush
      @metric_flusher
    end
  end

  extend Lifecycle
end
