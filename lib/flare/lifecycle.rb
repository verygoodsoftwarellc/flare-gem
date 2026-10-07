# frozen_string_literal: true

require "opentelemetry/sdk"

require_relative "deadline"

module Flare
  module Lifecycle
    FLUSH_TIMEOUT = 5 # seconds, total across traces and metrics

    # Flush all trace processors and the separate aggregated metric pipeline
    # using one monotonic timeout budget. This is safe to call from lifecycle
    # hooks for short-lived and fork-per-job workers. A nil timeout means the
    # default, not unbounded: a hung endpoint must not stall the worker.
    def force_flush(timeout: FLUSH_TIMEOUT)
      deadline = Deadline.new(timeout || FLUSH_TIMEOUT)
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

    SHUTDOWN_TIMEOUT = 5       # seconds, total across all of Flare
    TRACE_SHUTDOWN_TIMEOUT = 1 # seconds; sampled traces are expendable

    # Stop everything Flare runs in the background under one budget, in
    # priority order. Runs from at_exit in every forked worker, so it must
    # finish well before the platform's kill deadline even if endpoints hang.
    # Metrics (a minute of aggregated counts) get first claim on the time;
    # span/trace processors get what's left, capped at TRACE_SHUTDOWN_TIMEOUT.
    def shutdown(timeout: SHUTDOWN_TIMEOUT)
      deadline = Deadline.new(timeout)

      shutdown_step("rule manager") { @rule_manager&.stop(timeout: 0) }
      shutdown_step("metrics") { @metric_flusher&.stop(timeout: [deadline.remaining - TRACE_SHUTDOWN_TIMEOUT, 0].max) }

      traces = Deadline.new([deadline.remaining, TRACE_SHUTDOWN_TIMEOUT].min)
      if configuration.spans_enabled && @span_processor
        shutdown_step("span processor") { span_processor.shutdown(timeout: traces.remaining) }
      end
      shutdown_step("trace processor") { @trace_span_processor&.shutdown(timeout: traces.remaining) }
    end

    # Each step is isolated so one failure doesn't skip the rest.
    def shutdown_step(name)
      yield
    rescue => e
      warn "[Flare] #{name} shutdown error: #{e.message}"
    end

    def install_shutdown_hook
      return if @shutdown_hook_installed

      @shutdown_hook_installed = true
      at_exit { shutdown }
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
