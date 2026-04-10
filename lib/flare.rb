# frozen_string_literal: true

require_relative "flare/version"
require_relative "flare/configuration"

require "opentelemetry/sdk"

require_relative "flare/source_location"
require_relative "flare/metric_key"
require_relative "flare/metric_storage"
require_relative "flare/metric_span_processor"
require_relative "flare/metric_flusher"
require_relative "flare/backoff_policy"
require_relative "flare/metric_submitter"

module Flare
  class Error < StandardError; end

  MISSING_PARENT_ID = "0000000000000000"
  TRANSACTION_NAME_ATTRIBUTE = "flare.transaction_name" unless const_defined?(:TRANSACTION_NAME_ATTRIBUTE)

  module_function

  def configuration
    @configuration ||= Configuration.new
  end

  def configure
    yield(configuration) if block_given?
  end

  def enabled?
    configuration.enabled
  end

  # Set the transaction name for the current span. This overrides the
  # default name derived from Rails controller/action or job class.
  #
  # Useful for Rack middleware, mounted apps, or any request that
  # doesn't go through the Rails router.
  #
  #   Flare.transaction_name("RestApi::Routes::Audits#get")
  #
  def transaction_name(name)
    span = OpenTelemetry::Trace.current_span
    return unless span.respond_to?(:set_attribute)

    span.set_attribute(TRANSACTION_NAME_ATTRIBUTE, name)
  end

  def logger
    @logger ||= Logger.new(STDOUT)
  end

  def logger=(logger)
    @logger = logger
  end

  def log(message)
    return unless configuration.debug

    logger.info("[Flare] #{message}")
  end

  def exporter
    @exporter ||= begin
      require_relative "flare/sqlite_exporter"
      SQLiteExporter.new(configuration.database_path)
    rescue LoadError
      warn "[Flare] sqlite3 gem not found. Spans are disabled. Add `gem 'sqlite3'` to your Gemfile to enable the development dashboard."
      configuration.spans_enabled = false
      nil
    end
  end

  def exporter=(exporter)
    @exporter = exporter
  end

  def span_processor
    @span_processor ||= OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      exporter,
      max_queue_size: 1000,
      max_export_batch_size: 100,
      schedule_delay: 1000 # 1 second
    )
  end

  def span_processor=(span_processor)
    @span_processor = span_processor
  end

  def tracer
    @tracer ||= OpenTelemetry.tracer_provider.tracer("Flare", Flare::VERSION)
  end

  def untraced(&block)
    OpenTelemetry::Common::Utilities.untraced(&block)
  end

  def metric_storage
    @metric_storage
  end

  def metric_storage=(storage)
    @metric_storage = storage
  end

  def metric_flusher
    @metric_flusher
  end

  def metric_flusher=(flusher)
    @metric_flusher = flusher
  end

  # Manually flush metrics (useful for testing or forced flushes).
  def flush_metrics
    @metric_flusher&.flush_now || 0
  end

  # Re-initialize metric flusher after fork.
  # Call this from Puma/Unicorn after_fork hooks.
  def after_fork
    @metric_flusher&.after_fork
  end

  # Configure OpenTelemetry SDK and instrumentations. Must run before the
  # middleware stack is built so Rack/ActionPack can insert their middleware.
  # Note: metrics flusher is started separately via start_metrics_flusher
  # after user initializers have run.
  def configure_opentelemetry
    return if @otel_configured

    # Suppress noisy OTel INFO logs
    OpenTelemetry.logger = Logger.new(STDOUT, level: Logger::WARN)

    service_name = if defined?(Rails) && Rails.application
      Rails.application.class.module_parent_name.underscore rescue "rails_app"
    else
      "app"
    end

    # Require flare's bundled instrumentations
    require "opentelemetry-instrumentation-rack"
    require "opentelemetry-instrumentation-net_http"
    require "opentelemetry-instrumentation-active_support"
    require "opentelemetry/instrumentation/active_support/span_subscriber"
    require "opentelemetry-instrumentation-action_pack" if defined?(ActionController)
    require "opentelemetry-instrumentation-action_view" if defined?(ActionView)
    require "opentelemetry-instrumentation-active_job" if defined?(ActiveJob)

    # Tell the SDK not to try configuring OTLP from env vars.
    # Flare manages its own exporters (SQLite for spans, HTTP for metrics).
    ENV["OTEL_TRACES_EXPORTER"] ||= "none"

    log "Configuring OpenTelemetry (service=#{service_name})"

    OpenTelemetry::SDK.configure do |c|
      c.service_name = service_name

      # Spans: detailed trace data stored in SQLite
      if configuration.spans_enabled && exporter
        c.add_span_processor(span_processor)
        log "Spans enabled (database=#{configuration.database_path})"
      end

      # Auto-detect and install all OTel instrumentation gems in the bundle.
      # Apps can add gems like opentelemetry-instrumentation-sidekiq to their
      # Gemfile and they'll be picked up automatically.
      c.use_all(
        "OpenTelemetry::Instrumentation::Rack" => {
          untraced_requests: ->(env) {
            request = Rack::Request.new(env)
            return true if request.path.start_with?("/flare")

            configuration.ignore_request.call(request)
          }
        },
        # Name Sidekiq job spans after the worker class (e.g. "MyWorker
        # process") instead of the upstream default of the queue name
        # ("default process"), matching how ActiveJob spans are named.
        "OpenTelemetry::Instrumentation::Sidekiq" => {
          span_naming: :job_class,
        }
      )
    end

    # Subscribe to common ActiveSupport notification patterns
    # This captures SQL, cache, mailer, and custom notifications.
    # Required for both spans (detailed traces) and metrics (aggregated counters)
    # because DB, cache, and mailer data flows through ActiveSupport notifications.
    if configuration.spans_enabled || configuration.metrics_enabled
      subscribe_to_notifications
    end

    at_exit do
      log "Shutting down..."
      if configuration.spans_enabled && @span_processor
        span_processor.force_flush
        span_processor.shutdown
        log "Span processor flushed and stopped"
      end
      log "Shutdown complete"
    end

    @otel_configured = true
  end

  # Start the metrics flusher. Called from config.after_initialize so
  # user configuration (metrics_enabled, flush_interval, etc.) is applied.
  def start_metrics_flusher
    return unless configuration.metrics_enabled

    @metric_storage ||= MetricStorage.new
    metric_processor = MetricSpanProcessor.new(
      storage: @metric_storage,
      http_metrics_config: configuration.http_metrics_config
    )
    OpenTelemetry.tracer_provider.add_span_processor(metric_processor)

    log "Metrics enabled (endpoint=#{configuration.url} key=#{configuration.key ? 'present' : 'missing'})"

    if configuration.metrics_submission_configured?
      submitter = MetricSubmitter.new(
        endpoint: configuration.url,
        api_key: configuration.key
      )
      @metric_flusher = MetricFlusher.new(
        storage: @metric_storage,
        submitter: submitter,
        interval: configuration.metrics_flush_interval
      )
      @metric_flusher.start
      log "Metrics flusher started (interval=#{configuration.metrics_flush_interval}s)"

      at_exit { @metric_flusher&.stop }
    else
      log "Metrics submission not configured (missing url or key)"
    end
  end

  # Payload transformers for different notification types
  NOTIFICATION_TRANSFORMERS = {
    "sql.active_record" => ->(payload) {
      attrs = {}
      attrs["db.system"] = payload[:connection]&.adapter_name&.downcase rescue nil
      attrs["db.statement"] = payload[:sql] if payload[:sql]
      attrs["name"] = payload[:name] if payload[:name]
      attrs["db.name"] = payload[:connection]&.pool&.db_config&.name rescue nil
      # Capture source location (app code that triggered this query)
      SourceLocation.add_to_attributes(attrs)
      attrs
    },
    "instantiation.active_record" => ->(payload) {
      attrs = {}
      attrs["record_count"] = payload[:record_count] if payload[:record_count]
      attrs["class_name"] = payload[:class_name] if payload[:class_name]
      attrs
    },
    "cache_read.active_support" => ->(payload) {
      store = payload[:store]
      store_name = store.is_a?(String) ? store : store&.class&.name
      { "key" => payload[:key]&.to_s, "hit" => payload[:hit], "store" => store_name }
    },
    "cache_write.active_support" => ->(payload) {
      store = payload[:store]
      store_name = store.is_a?(String) ? store : store&.class&.name
      { "key" => payload[:key]&.to_s, "store" => store_name }
    },
    "cache_delete.active_support" => ->(payload) {
      store = payload[:store]
      store_name = store.is_a?(String) ? store : store&.class&.name
      { "key" => payload[:key]&.to_s, "store" => store_name }
    },
    "cache_exist?.active_support" => ->(payload) {
      store = payload[:store]
      store_name = store.is_a?(String) ? store : store&.class&.name
      { "key" => payload[:key]&.to_s, "exist" => payload[:exist], "store" => store_name }
    },
    "cache_fetch_hit.active_support" => ->(payload) {
      store = payload[:store]
      store_name = store.is_a?(String) ? store : store&.class&.name
      { "key" => payload[:key]&.to_s, "store" => store_name }
    },
    "deliver.action_mailer" => ->(payload) {
      attrs = {}
      attrs["mailer"] = payload[:mailer] if payload[:mailer]
      attrs["message_id"] = payload[:message_id] if payload[:message_id]
      attrs["to"] = Array(payload[:to]).join(", ") if payload[:to]
      attrs["subject"] = payload[:subject] if payload[:subject]
      attrs
    },
    "process.action_mailer" => ->(payload) {
      attrs = {}
      attrs["mailer"] = payload[:mailer] if payload[:mailer]
      attrs["action"] = payload[:action] if payload[:action]
      attrs
    }
  }.freeze

  def subscribe_to_notifications
    NOTIFICATION_TRANSFORMERS.each do |pattern, transformer|
      OpenTelemetry::Instrumentation::ActiveSupport.subscribe(tracer, pattern, transformer)
    rescue
      # Ignore errors for patterns that don't exist
    end

    # Auto-subscribe to custom patterns (default: "app.*")
    # This lets users just do: ActiveSupport::Notifications.instrument("app.whatever") { }
    subscribe_to_custom_patterns
  end

  def subscribe_to_custom_patterns
    configuration.subscribe_patterns.each do |prefix|
      # Subscribe to all notifications starting with this prefix
      pattern = /\A#{Regexp.escape(prefix)}/
      default_transformer = ->(payload) {
        attrs = payload.transform_keys(&:to_s).select { |_, v|
          v.is_a?(String) || v.is_a?(Numeric) || v.is_a?(TrueClass) || v.is_a?(FalseClass)
        }
        SourceLocation.add_to_attributes(attrs)
        attrs
      }
      OpenTelemetry::Instrumentation::ActiveSupport.subscribe(tracer, pattern, default_transformer)
    end
  end

  # Subscribe to any ActiveSupport::Notification and create spans for it
  #
  # @param pattern [String, Regexp] The notification pattern to subscribe to
  # @param transformer [Proc, nil] Optional proc to transform payload into span attributes
  #   If nil, all payload keys become span attributes
  #
  # @example Subscribe to a custom notification
  #   Flare.subscribe("my_service.call")
  #
  # @example Subscribe with custom attribute transformer
  #   Flare.subscribe("stripe.charge") do |payload|
  #     { "charge_id" => payload[:id], "amount" => payload[:amount] }
  #   end
  #
  def subscribe(pattern, &transformer)
    transformer ||= ->(payload) {
      # Default: convert all payload keys to string attributes
      payload.transform_keys(&:to_s).transform_values(&:to_s)
    }
    OpenTelemetry::Instrumentation::ActiveSupport.subscribe(tracer, pattern, transformer)
  end

  # Instrument a block of code, creating a span that shows up in Flare
  #
  # NOTE: This method only works when Flare is loaded (typically development).
  # For instrumentation that works in all environments, use ActiveSupport::Notifications
  # directly and subscribe with Flare.subscribe in your initializer.
  #
  # @param name [String] The name of the span (e.g., "my_service.call", "external_api.fetch")
  # @param attributes [Hash] Optional attributes to add to the span
  # @yield The block to instrument
  # @return The return value of the block
  #
  # @example Basic usage (dev only)
  #   Flare.instrument("geocoding.lookup") do
  #     geocoder.lookup(address)
  #   end
  #
  # @example For all environments, use ActiveSupport::Notifications instead:
  #   # In your app code (works everywhere):
  #   ActiveSupport::Notifications.instrument("myapp.geocoding", address: addr) do
  #     geocoder.lookup(addr)
  #   end
  #
  #   # In config/initializers/flare.rb (only loaded in dev):
  #   Flare.subscribe("myapp.geocoding")
  #
  def instrument(name, attributes = {}, &block)
    return yield unless enabled?

    # Add source location
    location = SourceLocation.find
    if location
      attributes["code.filepath"] = location[:filepath]
      attributes["code.lineno"] = location[:lineno]
      attributes["code.function"] = location[:function] if location[:function]
    end

    tracer.in_span(name, attributes: attributes, kind: :internal) do |span|
      yield span
    end
  end

  def storage
    @storage ||= begin
      require_relative "flare/storage/sqlite"
      Storage::SQLite.new(configuration.database_path)
    rescue LoadError
      warn "[Flare] sqlite3 gem not found. Dashboard is disabled. Add `gem 'sqlite3'` to your Gemfile to enable it."
      configuration.spans_enabled = false
      nil
    end
  end

  def reset_storage!
    @storage = nil
  end

  def reset!
    @configuration = nil
    @exporter = nil
    @span_processor = nil
    @tracer = nil
    @storage = nil
    @metric_flusher&.stop
    @metric_flusher = nil
    @metric_storage = nil
    @otel_configured = false
  end
end

require_relative "flare/storage"
require_relative "flare/engine" if defined?(Rails)
