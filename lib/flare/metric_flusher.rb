# frozen_string_literal: true

require "concurrent/timer_task"
require "concurrent/executor/fixed_thread_pool"
require "opentelemetry/sdk"

require_relative "deadline"

module Flare
  # Background threads that periodically drain in-memory metrics and submit
  # them via HTTP. Uses concurrent-ruby TimerTask + FixedThreadPool, matching
  # the pattern in Flipper's telemetry.
  #
  # Fork-safe: detects forked processes and restarts automatically.
  class MetricFlusher
    SUCCESS = OpenTelemetry::SDK::Trace::Export::SUCCESS
    FAILURE = OpenTelemetry::SDK::Trace::Export::FAILURE
    TIMEOUT = OpenTelemetry::SDK::Trace::Export::TIMEOUT
    DEFAULT_INTERVAL = 60 # seconds
    DEFAULT_SHUTDOWN_TIMEOUT = 5 # seconds

    attr_reader :interval, :shutdown_timeout

    def initialize(storage:, submitter:, interval: DEFAULT_INTERVAL, shutdown_timeout: DEFAULT_SHUTDOWN_TIMEOUT, health_reporters: [])
      @storage = storage
      @submitter = submitter
      @interval = interval
      @shutdown_timeout = shutdown_timeout
      @health_reporters = Array(health_reporters)
      @pid = $$
      @stopped = false
      initialize_synchronization
    end

    def start
      @stopped = false

      @pool = Concurrent::FixedThreadPool.new(1, {
        max_queue: 20,
        fallback_policy: :discard,
        name: "flare-metrics-submit-pool".freeze,
      })

      @timer = Concurrent::TimerTask.execute({
        execution_interval: @interval,
        name: "flare-metrics-drain-timer".freeze,
      }) { post_to_pool }
    end

    def stop(timeout: @shutdown_timeout)
      return if @stopped

      deadline = Deadline.new(timeout)
      @stopped = true

      log "Shutting down metrics flusher, draining remaining metrics..."

      if @timer
        @timer.shutdown
        @timer.wait_for_termination([deadline.remaining || 1, 1].min)
        @timer.kill unless @timer.shutdown?
      end

      force_flush(timeout: deadline.remaining)

      if @pool
        @pool.shutdown
        pool_terminated = @pool.wait_for_termination(deadline.remaining || @shutdown_timeout)
        @pool.kill unless pool_terminated
      end

      log "Metrics flusher stopped"
    end

    def restart
      @stopped = false
      stop
      start
    end

    # Manually trigger a flush (useful for testing or forced flushes).
    def flush_now(timeout: nil)
      return 0 unless @storage && @submitter

      detect_forking
      count, error, = flush_synchronously(Deadline.new(timeout))
      if error
        warn "[Flare] Metric submission error: #{error.message}"
      end
      count
    rescue => e
      warn "[Flare] Metric flush error: #{e.message}"
      0
    end

    def force_flush(timeout: nil)
      return SUCCESS unless @storage && @submitter

      detect_forking
      deadline = Deadline.new(timeout)
      _count, error, timed_out = flush_synchronously(deadline)
      return TIMEOUT if timed_out || deadline.expired?
      return FAILURE if error

      SUCCESS
    rescue => e
      warn "[Flare] Metric flush error: #{e.message}"
      FAILURE
    end

    def running?
      @timer&.running? || false
    end

    # Re-initialize after fork. Called automatically by MetricSpanProcessor
    # on first span in the new process, or manually from Puma/Unicorn
    # after_fork hooks.
    def after_fork
      @pid = $$
      @storage.after_fork if @storage.respond_to?(:after_fork)
      initialize_synchronization
      @timer = nil
      @pool = nil
      start
    end

    private

    def detect_forking
      after_fork if @pid != $$
    end

    def initialize_synchronization
      @submission_mutex = Mutex.new
      @submission_condition = ConditionVariable.new
      @pending_submissions = 0
      @flush_owner = nil
    end

    def post_to_pool
      return unless reserve_background_submission

      record_health_metrics
      drained = @storage.drain
      if drained.empty?
        log "No metrics to flush"
        background_submission_finished
        return
      end

      log "Drained #{drained.size} metric keys for submission"
      posted = @pool.post do
        submit_to_cloud(drained)
      ensure
        background_submission_finished
      end
      background_submission_finished unless posted
    rescue => e
      background_submission_finished
      warn "[Flare] Metric drain error: #{e.message}"
    end

    def submit_to_cloud(drained)
      _response, error = @submitter.submit(drained)
      if error
        warn "[Flare] Metric submission error: #{error.message}"
      end
    rescue => e
      warn "[Flare] Metric submission error: #{e.message}"
    end

    def reserve_background_submission
      @submission_mutex.synchronize do
        return false if @flush_owner || @pending_submissions.positive?

        @pending_submissions += 1
        true
      end
    end

    def background_submission_finished
      @submission_mutex.synchronize do
        @pending_submissions -= 1 if @pending_submissions.positive?
        @submission_condition.broadcast
      end
    end

    def flush_synchronously(deadline)
      return [0, nil, true] unless begin_synchronous_flush(deadline)

      record_health_metrics
      drained = @storage.drain
      return [0, nil, false] if drained.empty?

      submit_with_deadline(drained, deadline)
    ensure
      finish_synchronous_flush if @flush_owner == Thread.current
    end

    def begin_synchronous_flush(deadline)
      @submission_mutex.synchronize do
        while @flush_owner && @flush_owner != Thread.current
          return false if deadline.expired?

          @submission_condition.wait(@submission_mutex, deadline.remaining)
        end
        @flush_owner = Thread.current

        while @pending_submissions.positive?
          return false if deadline.expired?

          @submission_condition.wait(@submission_mutex, deadline.remaining)
        end
      end
      true
    end

    def finish_synchronous_flush
      @submission_mutex.synchronize do
        @flush_owner = nil
        @submission_condition.broadcast
      end
    end

    def submit_metrics(drained, timeout:)
      parameters = @submitter.method(:submit).parameters
      accepts_timeout = parameters.any? do |type, name|
        type == :keyrest || ([:key, :keyreq].include?(type) && name == :timeout)
      end

      if accepts_timeout
        @submitter.submit(drained, timeout: timeout)
      else
        @submitter.submit(drained)
      end
    end

    def submit_with_deadline(drained, deadline)
      operation = { done: false, count: 0, error: nil }
      @submission_mutex.synchronize { @pending_submissions += 1 }
      Thread.new do
        operation[:count], operation[:error] = submit_metrics(drained, timeout: deadline.remaining)
      rescue => e
        operation[:error] = e
      ensure
        @submission_mutex.synchronize do
          operation[:done] = true
          @pending_submissions -= 1
          @submission_condition.broadcast
        end
      end

      @submission_mutex.synchronize do
        until operation[:done]
          return [0, nil, true] if deadline.expired?

          @submission_condition.wait(@submission_mutex, deadline.remaining)
        end
      end

      timed_out = deadline.expired? || deadline_error?(operation[:error])
      [operation[:count], operation[:error], timed_out]
    end

    def deadline_error?(error)
      defined?(MetricSubmitter::DeadlineExceeded) && error.is_a?(MetricSubmitter::DeadlineExceeded)
    end

    def record_health_metrics
      @health_reporters.each { |reporter| reporter.record(@storage) }
    rescue => e
      warn "[Flare] Health metric recording error: #{e.message}"
    end

    def log(message)
      Flare.log(message) if Flare.respond_to?(:log)
    end
  end
end
