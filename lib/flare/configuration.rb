# frozen_string_literal: true

require_relative "http_metrics_config"

module Flare
  class Configuration
    attr_accessor :enabled
    attr_accessor :retention_hours
    attr_accessor :max_spans
    attr_accessor :ignore_request
    attr_writer :database_path

    # Spans: detailed trace data stored in SQLite (default: development only)
    # Metrics: aggregated counters in memory, flushed periodically (default: production only)
    attr_accessor :spans_enabled
    attr_accessor :metrics_enabled
    attr_accessor :metrics_flush_interval # seconds between flushes (default: 60)

    # Metrics HTTP submission settings
    attr_accessor :url        # URL of the Flare metrics service
    attr_accessor :key        # API key for authentication
    attr_accessor :metrics_timeout     # HTTP timeout in seconds (default: 5)
    attr_accessor :metrics_gzip        # Whether to gzip payloads (default: true)

    # Default patterns to auto-subscribe to for custom instrumentation
    # Use "app." prefix in your ActiveSupport::Notifications.instrument calls
    DEFAULT_SUBSCRIBE_PATTERNS = %w[app.].freeze

    attr_accessor :subscribe_patterns

    # HTTP metrics path tracking configuration.
    # Controls which outgoing HTTP paths are tracked with detail vs collapsed to "*".
    attr_reader :http_metrics_config

    # Enable debug logging to see what Flare is doing.
    # Set FLARE_DEBUG=1 or configure debug: true in your initializer.
    attr_accessor :debug

    def initialize
      @enabled = true
      @retention_hours = 24
      @max_spans = 10_000
      @database_path = nil
      @ignore_request = ->(request) { false }
      @subscribe_patterns = DEFAULT_SUBSCRIBE_PATTERNS.dup
      @debug = ENV["FLARE_DEBUG"] == "1"
      @http_metrics_config = HttpMetricsConfig::DEFAULT

      # Environment-based defaults:
      # - Development: spans ON (detailed debugging), metrics ON
      # - Production: spans OFF (too expensive), metrics ON
      # - Test: spans OFF, metrics OFF
      @spans_enabled = rails_development?
      @metrics_enabled = !rails_test?
      @metrics_flush_interval = 60 # seconds

      # Metrics HTTP submission defaults
      @url = ENV.fetch("FLARE_URL", credentials_url || "https://flare.am")
      @key = ENV["FLARE_KEY"]
      @metrics_timeout = 5
      @metrics_gzip = true
    end

    # Check if metrics can be submitted (endpoint and API key configured)
    def metrics_submission_configured?
      !@url.nil? && !@url.empty? &&
        !@key.nil? && !@key.empty?
    end

    def database_path
      @database_path || default_database_path
    end

    # Configure HTTP metrics path tracking.
    #
    #   config.http_metrics do |http|
    #     http.host "api.stripe.com" do |h|
    #       h.allow %r{/v1/customers}
    #       h.allow %r{/v1/charges}
    #       h.map %r{/v1/connect/[\w-]+/transfers}, "/v1/connect/:account/transfers"
    #     end
    #     http.host "api.github.com", :all
    #   end
    def http_metrics(&block)
      # Clone defaults on first customization so user additions merge with built-in defaults
      if @http_metrics_config.equal?(HttpMetricsConfig::DEFAULT)
        @http_metrics_config = @http_metrics_config.dup
      end
      yield @http_metrics_config
    end

    private

    def rails_development?
      defined?(Rails) && Rails.env.development?
    rescue StandardError
      false # Default to false for safety - avoids enabling spans unexpectedly in production
    end

    def rails_test?
      defined?(Rails) && Rails.env.test?
    rescue StandardError
      false
    end

    def credentials_url
      return nil unless defined?(Rails) && Rails.application&.credentials
      Rails.application.credentials.dig(:flare, :url)
    rescue StandardError
      nil
    end

    def default_database_path
      if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        Rails.root.join("db", "flare.sqlite3").to_s
      else
        "flare.sqlite3"
      end
    end
  end
end
