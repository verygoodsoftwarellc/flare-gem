# frozen_string_literal: true

require_relative "test_helper"
require "flare/metric_key"
require "flare/metric_storage"
require "flare/metric_flusher"
require "flare/metric_submitter"

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

  def test_flush_now_records_health_metrics_before_draining
    reporter = MockHealthReporter.new(create_key("sdk", "flare-ruby", "tracing", "dropped_spans"))
    flusher = Flare::MetricFlusher.new(
      storage: @storage,
      submitter: @submitter,
      interval: 1,
      health_reporters: [reporter]
    )

    count = flusher.flush_now

    assert_equal 1, count
    assert_equal 1, reporter.record_count
    submitted = @submitter.submitted_data.last
    assert_equal({ count: 1, sum_ms: 0, error_count: 0 }, submitted[reporter.key])
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
    old_timer = @flusher.instance_variable_get(:@timer)
    @flusher.instance_variable_set(:@pid, $$ + 1) # simulate being in a forked child

    @flusher.after_fork

    assert @flusher.running?
    refute_same old_timer, @flusher.instance_variable_get(:@timer)
    old_timer.shutdown
  end

  def test_after_fork_in_same_process_is_a_noop
    @flusher.start
    timer = @flusher.instance_variable_get(:@timer)

    @flusher.after_fork

    assert_same timer, @flusher.instance_variable_get(:@timer)
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

  def test_force_flush_waits_for_background_submission
    submitter = BlockingSubmitter.new
    flusher = Flare::MetricFlusher.new(storage: @storage, submitter: submitter, interval: 0.01)
    key = create_key("web", "rails", "UsersController", "show")
    @storage.increment(key, duration_ms: 100, error: false)
    flusher.start
    submitter.wait_until_started
    Thread.new { sleep 0.02; submitter.release }

    result = flusher.force_flush(timeout: 1)

    assert_equal OpenTelemetry::SDK::Trace::Export::SUCCESS, result
  ensure
    submitter&.release
    flusher&.stop
  end

  def test_force_flush_times_out_for_background_submission
    submitter = BlockingSubmitter.new
    flusher = Flare::MetricFlusher.new(storage: @storage, submitter: submitter, interval: 0.01)
    key = create_key("web", "rails", "UsersController", "show")
    @storage.increment(key, duration_ms: 100, error: false)
    flusher.start
    submitter.wait_until_started

    result = flusher.force_flush(timeout: 0.02)

    assert_equal OpenTelemetry::SDK::Trace::Export::TIMEOUT, result
  ensure
    submitter&.release
    flusher&.stop
  end

  def test_force_flush_clears_inherited_submission_state_after_fork
    flusher = Flare::MetricFlusher.new(storage: @storage, submitter: @submitter, interval: 60)
    flusher.instance_variable_set(:@pending_submissions, 1)
    reader, writer = IO.pipe

    pid = fork do
      reader.close
      writer.write(flusher.force_flush(timeout: 0.1).to_s)
      writer.close
      exit!
    end
    writer.close
    Process.wait(pid)

    assert_equal OpenTelemetry::SDK::Trace::Export::SUCCESS.to_s, reader.read
  ensure
    reader&.close
    writer&.close unless writer&.closed?
    flusher.instance_variable_set(:@pending_submissions, 0) if flusher
    flusher&.stop
  end

  def test_force_flush_is_bounded_when_submitter_ignores_timeout
    submitter = BlockingSubmitter.new
    flusher = Flare::MetricFlusher.new(storage: @storage, submitter: submitter, interval: 60)
    key = create_key("web", "rails", "UsersController", "show")
    @storage.increment(key, duration_ms: 100, error: false)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    result = flusher.force_flush(timeout: 0.02)

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    assert_equal OpenTelemetry::SDK::Trace::Export::TIMEOUT, result
    assert_operator elapsed, :<, 0.1
  ensure
    submitter&.release
    flusher&.stop
  end

  def test_after_fork_during_synchronous_flush_does_not_strand_the_flush
    submitter = ForkSignallingSubmitter.new
    flusher = Flare::MetricFlusher.new(storage: @storage, submitter: submitter, interval: 60)
    submitter.flusher = flusher
    key = create_key("web", "rails", "UsersController", "show")
    @storage.increment(key, duration_ms: 100, error: false)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    result = flusher.force_flush(timeout: 2)

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    assert_equal OpenTelemetry::SDK::Trace::Export::SUCCESS, result
    assert_operator elapsed, :<, 1
  ensure
    flusher&.stop
  end

  def test_force_flush_maps_deadline_submission_error_to_timeout
    submitter = DeadlineSubmitter.new
    flusher = Flare::MetricFlusher.new(storage: @storage, submitter: submitter, interval: 60)
    key = create_key("web", "rails", "UsersController", "show")
    @storage.increment(key, duration_ms: 100, error: false)

    result = flusher.force_flush(timeout: 1)

    assert_equal OpenTelemetry::SDK::Trace::Export::TIMEOUT, result
  ensure
    flusher&.stop
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
  class ForkSignallingSubmitter
    attr_accessor :flusher

    def submit(drained)
      @flusher.after_fork
      [drained.size, nil]
    end
  end

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

  class MockHealthReporter
    attr_reader :key, :record_count

    def initialize(key)
      @key = key
      @record_count = 0
    end

    def record(storage)
      @record_count += 1
      storage.add(@key, count: 1, sum_ms: 0)
    end
  end

  class BlockingSubmitter
    def initialize
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @started = false
      @released = false
    end

    def submit(drained, timeout: nil)
      @mutex.synchronize do
        @started = true
        @condition.broadcast
        @condition.wait(@mutex) until @released
      end
      [drained.size, nil]
    end

    def wait_until_started
      @mutex.synchronize { @condition.wait(@mutex) until @started }
    end

    def release
      @mutex.synchronize do
        @released = true
        @condition.broadcast
      end
    end
  end

  class DeadlineSubmitter
    def submit(_drained, timeout: nil)
      [0, Flare::MetricSubmitter::DeadlineExceeded.new("deadline")]
    end
  end
end
