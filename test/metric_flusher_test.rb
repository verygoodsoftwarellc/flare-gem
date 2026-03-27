# frozen_string_literal: true

require_relative "test_helper"
require "flare/metric_key"
require "flare/metric_storage"
require "flare/metric_flusher"

class MetricFlusherTest < Minitest::Test
  def setup
    @storage = Flare::MetricStorage.new
    @submitter = MockSubmitter.new
    @flusher = Flare::MetricFlusher.new(
      storage: @storage,
      submitter: @submitter,
      interval: 0.1 # 100ms for fast tests
    )
  end

  def teardown
    @flusher.stop
  end

  def test_default_interval
    flusher = Flare::MetricFlusher.new(storage: @storage, submitter: @submitter)
    assert_equal 60, flusher.interval
  end

  def test_custom_interval
    assert_equal 0.1, @flusher.interval
  end

  def test_start_creates_running_timer
    refute @flusher.running?

    @flusher.start

    assert @flusher.running?
  end

  def test_stop_stops_timer
    @flusher.start
    assert @flusher.running?

    @flusher.stop

    refute @flusher.running?
  end

  def test_stop_flushes_remaining_data
    @flusher.start

    key = create_key("web", "rails", "UsersController", "show")
    @storage.increment(key, duration_ms: 100, error: false)

    @flusher.stop

    assert @submitter.submit_count >= 1
  end

  def test_flush_now_drains_storage
    key = create_key("web", "rails", "UsersController", "show")
    @storage.increment(key, duration_ms: 100, error: false)

    count = @flusher.flush_now

    assert_equal 1, count
    assert @storage.empty?
  end

  def test_background_flush_occurs
    @flusher.start

    key = create_key("web", "rails", "UsersController", "show")
    @storage.increment(key, duration_ms: 100, error: false)

    # Wait for timer to drain and pool to submit
    sleep 0.3

    assert @submitter.submit_count >= 1
  end

  def test_after_fork_keeps_running
    @flusher.start
    assert @flusher.running?

    @flusher.after_fork

    assert @flusher.running?
  end

  def test_flush_now_handles_nil_storage
    flusher = Flare::MetricFlusher.new(storage: nil, submitter: @submitter, interval: 1)
    count = flusher.flush_now

    assert_equal 0, count
  end

  def test_flush_now_handles_nil_submitter
    flusher = Flare::MetricFlusher.new(storage: @storage, submitter: nil, interval: 1)
    count = flusher.flush_now

    assert_equal 0, count
  end

  private

  def create_key(namespace, service, target, operation)
    Flare::MetricKey.new(
      bucket: Time.now.utc,
      namespace: namespace,
      service: service,
      target: target,
      operation: operation
    )
  end

  # Mock submitter for testing
  class MockSubmitter
    attr_reader :submit_count, :submitted_data

    def initialize
      @submit_count = 0
      @submitted_data = []
      @mutex = Mutex.new
    end

    def submit(drained)
      @mutex.synchronize do
        @submitted_data << drained
        @submit_count += 1
      end
      [drained.size, nil]
    end
  end
end
