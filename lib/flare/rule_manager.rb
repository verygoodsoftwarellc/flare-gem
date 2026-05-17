# frozen_string_literal: true

require "json"
require "logger"
require "concurrent/timer_task"
require "concurrent/atomic/atomic_fixnum"

require_relative "http_transport"

module Flare
  # The SDK's only poll. Every interval seconds (default 30) it does a
  # GET /api/rules; the 200 response carries the active TraceRules (with
  # server-computed sample_rate) plus a bag of presigned R2 PUT URLs.
  # We hand the rules to Sampler#update_rules and the URLs to
  # UploadUrlPool#replace, and sweep the Marker so stuck rack-span
  # entries don't linger.
  #
  # ETag-guarded: subsequent polls send If-None-Match. A 304 still gets
  # us a Marker.sweep but doesn't touch sampler or pool. 401/403 stops
  # the poller (misconfigured token shouldn't beat down the server).
  # 5xx and exceptions are logged + counted; the timer just tries again
  # on the next tick.
  #
  # Fork-safe: after_fork clears the pool and restarts the timer in the
  # child process so each child polls independently.
  class RuleManager
    DEFAULT_INTERVAL = 30

    attr_reader :poll_count, :etag, :stopped_due_to_auth, :last_error_count

    def initialize(sampler:, marker:, pool:, base_url:, api_key:, project:, environment:,
                   interval: DEFAULT_INTERVAL, transport: nil, logger: nil)
      @sampler     = sampler
      @marker      = marker
      @pool        = pool
      @rules_url   = "#{base_url.to_s.chomp('/')}/api/rules"
      @api_key     = api_key
      @project     = project
      @environment = environment
      @interval    = interval
      @transport   = transport || HttpTransport.new
      @logger      = logger || Logger.new($stderr, level: Logger::WARN)

      @etag = nil
      @poll_count          = Concurrent::AtomicFixnum.new(0)
      @last_error_count    = Concurrent::AtomicFixnum.new(0)
      @stopped_due_to_auth = false
      @pid                 = $$
    end

    def start
      return self if @timer || @stopped_due_to_auth

      @timer = Concurrent::TimerTask.execute(
        execution_interval: @interval,
        run_now:            true,
        name:               "flare-rule-manager-timer"
      ) { poll_safely }
      self
    end

    def stop
      if @timer
        @timer.shutdown
        @timer.wait_for_termination(1)
        @timer.kill unless @timer.shutdown?
        @timer = nil
      end
      self
    end

    def running?
      @timer ? @timer.running? : false
    end

    def after_fork
      @pid = $$
      @pool.after_fork
      stop
      start
    end

    # Public so callers can force a poll (tests + integration tests).
    def poll_now
      poll_safely
    end

    private

    def poll_safely
      poll
    rescue StandardError => e
      @last_error_count.increment
      @logger.warn("[Flare::RuleManager] poll exception: #{e.class}: #{e.message}")
    end

    def poll
      return if @stopped_due_to_auth

      response = @transport.get(@rules_url, request_headers)
      @poll_count.increment

      case response.code
      when "304"
        @marker.sweep
      when "200"
        @etag = response.header("ETag")
        apply(JSON.parse(response.body))
        @marker.sweep
      when "401", "403"
        @stopped_due_to_auth = true
        @logger.warn("[Flare::RuleManager] auth failed (#{response.code}); stopping poll")
        stop
      else
        @last_error_count.increment
        @logger.warn("[Flare::RuleManager] unexpected #{response.code}")
      end
    end

    def request_headers
      headers = {
        "Authorization"     => "Bearer #{@api_key}",
        "Flare-Project"     => @project,
        "Flare-Environment" => @environment
      }
      headers["If-None-Match"] = @etag if @etag
      headers
    end

    # Server payload shape (see tirana-v2 Api::RulesController):
    #   { "trace_rules": [{ "id", "match_attributes", "rate", ..., "urls": [...] }] }
    def apply(payload)
      rules = payload["trace_rules"] || []
      @sampler.update_rules(rules)

      url_entries = rules.flat_map { |r| Array(r["urls"]) }
      @pool.replace(url_entries)
    end
  end
end
