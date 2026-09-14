# frozen_string_literal: true

require "logger"
require "opentelemetry/sdk"

require_relative "deadline"

module Flare
  # An asynchronous, bounded span processor that exports every ended recording
  # span. OpenTelemetry's BatchSpanProcessor only accepts sampled spans, which
  # excludes RECORD_ONLY spans needed by Flare's local development dashboard.
  class RecordingBatchSpanProcessor
    SUCCESS = OpenTelemetry::SDK::Trace::Export::SUCCESS
    FAILURE = OpenTelemetry::SDK::Trace::Export::FAILURE
    TIMEOUT = OpenTelemetry::SDK::Trace::Export::TIMEOUT

    def initialize(exporter, exporter_timeout: 30_000, schedule_delay: 5_000,
                   max_queue_size: 2_048, max_export_batch_size: 512, logger: nil)
      raise ArgumentError if max_export_batch_size > max_queue_size

      @exporter = exporter
      @exporter_timeout = exporter_timeout / 1_000.0
      @schedule_delay = schedule_delay / 1_000.0
      @max_queue_size = max_queue_size
      @max_export_batch_size = max_export_batch_size
      @logger = logger || Logger.new($stderr, level: Logger::WARN)
      @pid = $$
      initialize_synchronization
      start_worker
    end

    def on_start(_span, _parent_context); end

    def on_finish(span)
      detect_forking

      @mutex.synchronize do
        overflow = @queue.length + 1 - @max_queue_size
        @queue.shift(overflow) if overflow.positive?
        @queue << span
        @condition.signal if @queue.length >= @max_export_batch_size
      end
    end

    def force_flush(timeout: nil)
      detect_forking
      deadline = Deadline.new(timeout)
      return TIMEOUT unless begin_flush(deadline)

      snapshot = snapshot_for_flush
      operation = start_flush_export(snapshot, deadline)
      wait_for_flush_export(operation, deadline)
    rescue StandardError => e
      log_export_error(e)
      FAILURE
    ensure
      finish_flush if @flush_owner == Thread.current
    end

    def shutdown(timeout: nil)
      detect_forking
      deadline = Deadline.new(timeout)

      worker = @mutex.synchronize do
        @stopped = true
        @condition.broadcast
        @worker
      end
      worker&.join(deadline.remaining)
      return TIMEOUT if worker&.alive? || deadline.expired?

      result = force_flush(timeout: deadline.remaining)
      return result unless result == SUCCESS
      return TIMEOUT if deadline.expired?

      exporter_result = @exporter.shutdown(timeout: deadline.remaining)
      deadline.expired? ? TIMEOUT : exporter_result
    rescue StandardError => e
      log_export_error(e)
      FAILURE
    end

    private

    def initialize_synchronization
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @queue = []
      @active_exports = 0
      @flush_owner = nil
      @stopped = false
      @worker = nil
    end

    def worker_loop
      loop do
        batch = @mutex.synchronize do
          while !@stopped && (@queue.empty? || @flush_owner || @active_exports.positive?)
            @condition.wait(@mutex, @schedule_delay)
            break if !@queue.empty? && !@flush_owner && @active_exports.zero?
          end
          return if @stopped

          @active_exports += 1
          @queue.shift(@max_export_batch_size)
        end

        export_batch(batch, timeout: @exporter_timeout)
      ensure
        export_finished if batch
      end
    end

    def begin_flush(deadline)
      @mutex.synchronize do
        while @flush_owner && @flush_owner != Thread.current
          return false if deadline.expired?

          @condition.wait(@mutex, deadline.remaining)
        end
        @flush_owner = Thread.current

        while @active_exports.positive?
          return false if deadline.expired?

          @condition.wait(@mutex, deadline.remaining)
        end
      end
      true
    end

    def finish_flush
      @mutex.synchronize do
        @flush_owner = nil
        @condition.broadcast
      end
    end

    def snapshot_for_flush
      @mutex.synchronize { @queue.shift(@queue.length) }
    end

    def export_snapshot(snapshot, deadline)
      until snapshot.empty?
        return TIMEOUT if deadline.expired?

        batch = snapshot.shift(@max_export_batch_size)
        result = export_batch(batch, timeout: deadline.remaining)
        return result unless result == SUCCESS
      end
      SUCCESS
    ensure
      @mutex.synchronize { @queue.unshift(*snapshot) } if snapshot&.any?
    end

    def start_flush_export(snapshot, deadline)
      operation = { done: false, result: nil }
      @mutex.synchronize { @active_exports += 1 }
      Thread.new do
        result = export_snapshot(snapshot, deadline)
        if result == SUCCESS && !deadline.expired?
          result = @exporter.force_flush(timeout: deadline.remaining)
        end
        operation[:result] = deadline.expired? ? TIMEOUT : result
      rescue StandardError => e
        log_export_error(e)
        operation[:result] = FAILURE
      ensure
        @mutex.synchronize do
          operation[:done] = true
          @active_exports -= 1
          @condition.broadcast
        end
      end
      operation
    end

    def wait_for_flush_export(operation, deadline)
      @mutex.synchronize do
        until operation[:done]
          return TIMEOUT if deadline.expired?

          @condition.wait(@mutex, deadline.remaining)
        end
      end
      operation[:result]
    end

    def export_batch(spans, timeout:)
      span_data = spans.map { |span| span.respond_to?(:to_span_data) ? span.to_span_data : span }
      @exporter.export(span_data, timeout: timeout)
    rescue StandardError => e
      log_export_error(e)
      FAILURE
    end

    def export_finished
      @mutex.synchronize do
        @active_exports -= 1
        @condition.broadcast
      end
    end

    def detect_forking
      return if @pid == $$

      # Only the forking thread survives. Replacing synchronization objects
      # avoids waiting on locks or in-flight state owned by vanished threads.
      @pid = $$
      initialize_synchronization
      start_worker
    end

    def start_worker
      @worker = Thread.new { worker_loop }
      @worker.name = "flare-recording-batch-span-processor"
    end

    def log_export_error(error)
      @logger.warn("[Flare::RecordingBatchSpanProcessor] export failed: #{error.class}: #{error.message}")
    end
  end
end
