# frozen_string_literal: true

require "concurrent/timer_task"
require "concurrent/executor/fixed_thread_pool"

module Flare
  # Background threads that periodically drain in-memory metrics and submit
  # them via HTTP. Uses concurrent-ruby TimerTask + FixedThreadPool, matching
  # the pattern in Flipper's telemetry.
  #
  # Fork-safe: detects forked processes and restarts automatically.
  class MetricFlusher
    DEFAULT_INTERVAL = 60 # seconds
    DEFAULT_SHUTDOWN_TIMEOUT = 5 # seconds

    attr_reader :interval, :shutdown_timeout

    def initialize(storage:, submitter:, interval: DEFAULT_INTERVAL, shutdown_timeout: DEFAULT_SHUTDOWN_TIMEOUT)
      @storage = storage
      @submitter = submitter
      @interval = interval
      @shutdown_timeout = shutdown_timeout
      @pid = $$
      @stopped = false
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

    def stop
      return if @stopped

      @stopped = true

      Flare.log "Shutting down metrics flusher, draining remaining metrics..."

      if @timer
        @timer.shutdown
        @timer.wait_for_termination(1)
        @timer.kill unless @timer.shutdown?
      end

      if @pool
        post_to_pool # one last drain
        @pool.shutdown
        pool_terminated = @pool.wait_for_termination(@shutdown_timeout)
        @pool.kill unless pool_terminated
      end

      Flare.log "Metrics flusher stopped"
    end

    def restart
      @stopped = false
      stop
      start
    end

    # Manually trigger a flush (useful for testing or forced flushes).
    def flush_now
      return 0 unless @storage && @submitter

      drained = @storage.drain
      return 0 if drained.empty?

      count, error = @submitter.submit(drained)
      if error
        warn "[Flare] Metric submission error: #{error.message}"
      end
      count
    rescue => e
      warn "[Flare] Metric flush error: #{e.message}"
      0
    end

    def running?
      @timer&.running? || false
    end

    # Re-initialize after fork. Called automatically by MetricSpanProcessor
    # on first span in the new process, or manually from Puma/Unicorn
    # after_fork hooks.
    def after_fork
      @pid = $$
      restart
    end

    private

    def post_to_pool
      drained = @storage.drain
      if drained.empty?
        Flare.log "No metrics to flush"
        return
      end

      Flare.log "Drained #{drained.size} metric keys for submission"
      @pool.post { submit_to_cloud(drained) }
    rescue => e
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
  end
end
