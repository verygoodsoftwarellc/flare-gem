# frozen_string_literal: true

require "opentelemetry/sdk"

module Flare
  # BatchSpanProcessor drops RECORD_ONLY spans before enqueueing them. Local
  # recording needs every completed span, regardless of the remote sampling
  # decision, while retaining the SDK processor's asynchronous queue, flush,
  # shutdown, overflow, and fork behavior.
  #
  # The wrapper changes only the context observed by BatchSpanProcessor's
  # sampled? gate. The original span's to_span_data is delegated unchanged to
  # the exporter.
  class RecordingBatchSpanProcessor
    def initialize(exporter,
                   exporter_timeout: Float(ENV.fetch("OTEL_BSP_EXPORT_TIMEOUT", 30_000)),
                   schedule_delay: Float(ENV.fetch("OTEL_BSP_SCHEDULE_DELAY", 5_000)),
                   max_queue_size: Integer(ENV.fetch("OTEL_BSP_MAX_QUEUE_SIZE", 2048)),
                   max_export_batch_size: Integer(ENV.fetch("OTEL_BSP_MAX_EXPORT_BATCH_SIZE", 512)),
                   start_thread_on_boot: String(ENV.fetch("OTEL_RUBY_BSP_START_THREAD_ON_BOOT", nil)) !~ /false/i,
                   metrics_reporter: nil)
      @processor = OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
        exporter,
        exporter_timeout: exporter_timeout,
        schedule_delay: schedule_delay,
        max_queue_size: max_queue_size,
        max_export_batch_size: max_export_batch_size,
        start_thread_on_boot: start_thread_on_boot,
        metrics_reporter: metrics_reporter
      )
    end

    def on_start(span, parent_context)
      @processor.on_start(span, parent_context)
    end

    def on_finish(span)
      @processor.on_finish(RecordingSpan.new(span))
    end

    def force_flush(timeout: nil)
      @processor.force_flush(timeout: timeout)
    end

    def shutdown(timeout: nil)
      @processor.shutdown(timeout: timeout)
    end

    private

    class RecordingSpan
      def initialize(span)
        @span = span
      end

      def context
        RecordingContext.new(@span.context)
      end

      def to_span_data
        @span.to_span_data
      end

      def method_missing(name, *args, &block)
        @span.public_send(name, *args, &block)
      end

      def respond_to_missing?(name, include_private = false)
        @span.respond_to?(name, include_private)
      end
    end

    class RecordingContext
      def initialize(context)
        @context = context
      end

      def trace_flags
        OpenTelemetry::Trace::TraceFlags::SAMPLED
      end

      def method_missing(name, *args, &block)
        @context.public_send(name, *args, &block)
      end

      def respond_to_missing?(name, include_private = false)
        @context.respond_to?(name, include_private)
      end
    end
  end
end
