# frozen_string_literal: true

require_relative "test_helper"
require "flare/recording_batch_span_processor"

class RecordingBatchRequeueTest < Minitest::Test
  def test_expired_flush_restores_only_spans_that_fit_the_queue_bound
    exporter = Struct.new(:exports) do
      def export(spans, timeout: nil)
        exports.concat(spans)
        OpenTelemetry::SDK::Trace::Export::SUCCESS
      end

      def force_flush(timeout: nil)
        OpenTelemetry::SDK::Trace::Export::SUCCESS
      end

      def shutdown(timeout: nil)
        OpenTelemetry::SDK::Trace::Export::SUCCESS
      end
    end.new([])
    processor = Flare::RecordingBatchSpanProcessor.new(exporter, max_queue_size: 3, max_export_batch_size: 3)
    # A flush owns the worker while its captured snapshot is outside the queue.
    # Keep that state deterministic while new spans arrive, before the expired
    # snapshot is restored by the same method force_flush uses.
    processor.instance_variable_get(:@mutex).synchronize do
      processor.instance_variable_set(:@flush_owner, Thread.current)
    end
    newest = %w[new-1 new-2 new-3]
    newest.each { |span| processor.on_finish(span) }

    result = processor.send(:export_snapshot, %w[old-1 old-2 old-3], Flare::Deadline.new(0))

    assert_equal OpenTelemetry::SDK::Trace::Export::TIMEOUT, result
    assert_operator processor.instance_variable_get(:@queue).size, :<=, 3
    processor.force_flush(timeout: 1)
    assert_equal newest, exporter.exports, "overflow must discard oldest spans, like normal enqueue"
  ensure
    processor&.shutdown(timeout: 1)
  end
end
