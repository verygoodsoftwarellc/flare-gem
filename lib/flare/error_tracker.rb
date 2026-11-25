# frozen_string_literal: true

require "json"
require "logger"
require "set"
require "time"
require "concurrent/atomic/atomic_boolean"
require "concurrent/atomic/atomic_fixnum"
require "concurrent/executor/single_thread_executor"

require_relative "client_headers"
require_relative "error_fingerprint"
require_relative "error_sample"
require_relative "metric_key"
require_relative "metric_storage"

module Flare
  # Counts errors by fingerprint and holds one sample of each new one.
  #
  # Errors come in three ways: the Rails error reporter (handled and
  # unhandled), Flare.report, and failed web requests and jobs whose spans
  # recorded an exception the reporter didn't see. Each exception object
  # counts once, whichever way it arrives first.
  #
  # Counts go out with the metrics flush as namespace "error" rows; the
  # MetricFlusher calls #record before it drains. Samples wait here until
  # the next /api/rules poll asks for upload URLs (RuleManager sends the
  # Flare-Error-Samples header), then upload in the background.
  #
  # Inert until /api/rules says error_tracking: true: nothing is counted,
  # held, asked for or sent while the gate is off.
  class ErrorTracker
    NAMESPACE = "error"
    SAMPLES_HEADER = "Flare-Error-Samples"
    MAX_FINGERPRINTS_PER_FLUSH = 100
    # Fingerprints past the per-flush cap count here.
    OVERFLOW_FINGERPRINT = "ffffffffffffffff"
    OVERFLOW_SERVICE = "overflow"
    MAX_SERVICE_LENGTH = 100
    MAX_OPERATION_LENGTH = 255
    MAX_WAITING_SAMPLES = 20
    MAX_REQUESTED_SAMPLES = 10
    MAX_SEEN_FINGERPRINTS = 10_000
    FINGERPRINT_PATTERN = /\A[0-9a-f]{16}\z/
    # Rails reports cache store errors it already rescued and fell back from.
    SKIP_SOURCES = /_cache_store\.active_support\z/
    ACTIVE_JOB_ERROR_STATUS = /\AUnexpected ActiveJob Error (\S+)\z/
    WRAPPER_CLASSES = %w[ActionView::Template::Error].freeze
    SPAN_EXCEPTION_KEY = :__flare_span_exception

    class << self
      # The process's tracker, set by Flare.setup_error_tracker. Read by
      # SpanExceptionCapture and Flare.report.
      attr_accessor :current
    end

    attr_reader :refused_count, :upload_count, :dropped_sample_count

    def initialize(configuration: Flare.configuration, uploader: nil, executor: nil,
                   clock: Time, logger: nil)
      @configuration = configuration
      @uploader = uploader
      @executor_override = executor
      @clock = clock
      @logger = logger || Logger.new($stderr, level: Logger::WARN)
      @enabled = Concurrent::AtomicBoolean.new(false)
      @refused_count = Concurrent::AtomicFixnum.new(0)
      @upload_count = Concurrent::AtomicFixnum.new(0)
      @dropped_sample_count = Concurrent::AtomicFixnum.new(0)
      reset_state
    end

    def enabled?
      @enabled.true?
    end

    # Set from each /api/rules response. Turning off drops whatever is
    # waiting so nothing is sent until it's back on.
    def enabled=(value)
      if value
        @enabled.make_true
      elsif @enabled.make_false
        @counts.drain
        @mutex.synchronize { @waiting.clear }
      end
    end

    # Records one occurrence. Returns true when it counted, false when the
    # gate is off, the error is ignored, or this exception already counted.
    # Never raises into the app.
    def report(exception, handled:, context: nil, source: nil, span: nil, operation: nil)
      return false unless enabled? && exception.is_a?(Exception)
      return false if source && SKIP_SOURCES.match?(source.to_s)

      detect_forking
      error = unwrap(exception)
      return false if ignored?(error)
      return false unless claim(exception, error)

      record_occurrence(error, handled: handled, context: context || {}, source: source, span: span, operation: operation)
      true
    rescue StandardError => e
      warn_once(e)
      false
    end

    # Called by MetricSpanProcessor for every web request and job span.
    # A failed one counts when its exception is known and wasn't reported.
    def entry_span_finished(span, operation:, error:)
      return unless enabled?

      exception = span_exception(span) if error
      Thread.current[SPAN_EXCEPTION_KEY] = nil
      report(exception, handled: false, span: span, operation: operation) if exception
    end

    # From SpanExceptionCapture: the exception object behind a span's
    # exception event, so spans and the reporter can dedupe on it.
    def remember_span_exception(span, exception)
      return unless enabled?

      span.instance_variable_set(:@flare_exception, exception)
      Thread.current[SPAN_EXCEPTION_KEY] = [span.context.trace_id, exception]
    rescue StandardError
      nil
    end

    # MetricFlusher hook, called before each drain: moves this flush's error
    # counts into the metric storage, at most MAX_FINGERPRINTS_PER_FLUSH
    # fingerprints, the rest under OVERFLOW_FINGERPRINT.
    def record(storage, **)
      detect_forking
      drained = @counts.drain
      return if drained.empty? || !enabled?

      totals = Hash.new(0)
      drained.each { |key, values| totals[key.target] += values[:count] }
      kept = totals.size > MAX_FINGERPRINTS_PER_FLUSH ? totals.max_by(MAX_FINGERPRINTS_PER_FLUSH, &:last).to_set(&:first) : nil

      drained.each do |key, values|
        key = overflow_key(key) if kept && !kept.include?(key.target)
        storage.add(key, count: values[:count], sum_ms: 0, error_count: values[:error_count])
      end
    end

    # Fingerprints to ask upload URLs for on this poll (sent as
    # Flare-Error-Samples). Empty when nothing waits, so the poll keeps its
    # ETag / 304 behavior.
    def sample_request
      return [] unless enabled?

      detect_forking
      @mutex.synchronize { @waiting.select { |_, sample| sample }.keys.first(MAX_REQUESTED_SAMPLES) }
    end

    # Applies a 200 /api/rules response. `requested` is what this poll asked
    # for; any of those without an entry in error_uploads was refused, and
    # its sample is dropped (the fingerprint stays seen, so it isn't asked
    # for again until the process restarts).
    def apply_rules(payload, requested: [])
      self.enabled = payload["error_tracking"] == true
      return unless enabled?

      granted = {}
      Array(payload["error_uploads"]).each do |raw|
        entry = upload_entry(raw)
        granted[entry[:fingerprint]] ||= entry if entry && requested.include?(entry[:fingerprint])
      end

      uploads = @mutex.synchronize do
        requested.filter_map do |fingerprint|
          sample = @waiting.delete(fingerprint)
          next unless sample

          if granted[fingerprint]
            [sample, granted[fingerprint]]
          else
            @refused_count.increment
            nil
          end
        end
      end
      uploads.each { |sample, entry| upload(sample, entry) }
    end

    def waiting_count
      @mutex.synchronize { @waiting.count { |_, sample| sample } }
    end

    def after_fork
      return if @pid == $$

      reset_state
    end

    private

    def reset_state
      @pid = $$
      @counts = MetricStorage.new
      @mutex = Mutex.new
      @claimed = ObjectSpace::WeakMap.new
      @waiting = {}
      @seen = Set.new
      @executor = nil
    end

    def detect_forking
      after_fork if @pid != $$
    end

    def record_occurrence(error, handled:, context:, source:, span:, operation:)
      now = @clock.now
      frames = ErrorFingerprint.frames(error)
      class_name = error.class.name || ErrorFingerprint.normalize_class(error.class.to_s)
      fingerprint = ErrorFingerprint.fingerprint(class_name, frames)
      span ||= current_span
      operation = (operation || operation_for(context, span)).to_s[0, MAX_OPERATION_LENGTH]

      key = MetricKey.new(
        bucket: Time.utc(now.year, now.month, now.day, now.hour, now.min, 0),
        namespace: NAMESPACE,
        service: class_name[0, MAX_SERVICE_LENGTH],
        target: fingerprint,
        operation: operation
      )
      @counts.increment(key, duration_ms: 0, error: !handled)

      trace_id = hex_trace_id(span)
      revision = @configuration.revision
      meta = { fingerprint: fingerprint, occurred_at: now.utc.iso8601(3), revision: revision, hex_trace_id: trace_id }
      hold_sample(fingerprint, meta) do
        controller = context[:controller]
        ErrorSample.build(
          exception: error,
          class_name: class_name,
          fingerprint: fingerprint,
          frames: frames,
          handled: handled ? true : false,
          operation: operation,
          occurred_at: now,
          revision: revision,
          host: ClientHeaders.hostname,
          hex_trace_id: trace_id,
          route: route_for(controller, span),
          params: param_names_for(controller, context),
          source: source&.to_s
        )
      end
    end

    # One sample per fingerprint per process, at most MAX_WAITING_SAMPLES
    # waiting. The slot is taken before the (slower) build so concurrent
    # errors can't overfill it.
    def hold_sample(fingerprint, meta)
      @mutex.synchronize do
        return if @seen.include?(fingerprint) || @waiting.size >= MAX_WAITING_SAMPLES || @seen.size >= MAX_SEEN_FINGERPRINTS

        @seen << fingerprint
        @waiting[fingerprint] = nil
      end

      json = yield
      @mutex.synchronize do
        if json && enabled?
          @waiting[fingerprint] = meta.merge(json: json)
        else
          @dropped_sample_count.increment unless json
          @waiting.delete(fingerprint)
        end
      end
    rescue StandardError
      @mutex.synchronize { @waiting.delete(fingerprint) unless @waiting[fingerprint] }
      raise
    end

    def upload(sample, entry)
      return unless @uploader

      executor.post do
        @upload_count.increment if @uploader.upload(sample, entry)
      rescue StandardError => e
        @logger.warn("[Flare::ErrorTracker] upload raised: #{e.class}: #{e.message}")
      end
    end

    def executor
      @executor_override || @executor ||= Concurrent::SingleThreadExecutor.new(
        max_queue: MAX_REQUESTED_SAMPLES * 2,
        fallback_policy: :discard
      )
    end

    def upload_entry(raw)
      return nil unless raw.is_a?(Hash)

      entry = raw.transform_keys(&:to_s).slice("fingerprint", "upload_id", "key", "put_url", "expires_at")
      return nil unless entry["fingerprint"].to_s.match?(FINGERPRINT_PATTERN)
      return nil if entry["upload_id"].to_s.empty? || entry["key"].to_s.empty? || entry["put_url"].to_s.empty?

      entry.transform_keys(&:to_sym)
    end

    def overflow_key(key)
      MetricKey.new(bucket: key.bucket, namespace: NAMESPACE, service: OVERFLOW_SERVICE,
                    target: OVERFLOW_FINGERPRINT, operation: key.operation)
    end

    # Marks the exception (and what it wraps) as counted. False when it
    # already was.
    def claim(exception, error)
      @mutex.synchronize do
        return false if @claimed.key?(exception) || @claimed.key?(error)

        @claimed[exception] = true
        @claimed[error] = true
      end
      true
    end

    # ActionView::Template::Error wraps the error the view raised.
    def unwrap(exception)
      if WRAPPER_CLASSES.include?(exception.class.name) && exception.cause
        exception.cause
      else
        exception
      end
    end

    def ignored?(error)
      ignored = Array(@configuration.ignore_errors) + Array(@configuration.error_tracking_ignores)
      return false if ignored.empty?

      error.class.ancestors.any? { |ancestor| ignored.include?(ancestor.name) }
    end

    # The span's own exception, or for a job whose retry recorded it on a
    # child span, the one this thread recorded last in the same trace when
    # the span names its class.
    def span_exception(span)
      own = span.instance_variable_get(:@flare_exception)
      return own if own

      trace_id, exception = Thread.current[SPAN_EXCEPTION_KEY]
      return nil unless exception && trace_id == span.context.trace_id

      exception if exception_type(span) == exception.class.name
    end

    def exception_type(span)
      event = span.events&.reverse_each&.find { |e| e.name == "exception" }
      event&.attributes&.[]("exception.type") ||
        span.status&.description.to_s[ACTIVE_JOB_ERROR_STATUS, 1]
    end

    def operation_for(context, span)
      controller = context[:controller]
      if controller.respond_to?(:action_name) && controller.action_name
        "#{controller.class.name}##{controller.action_name}"
      elsif context[:job]
        context[:job].class.name
      elsif context[:operation]
        context[:operation]
      else
        span_operation(span) || "unknown"
      end
    end

    def span_operation(span)
      attributes = span_attributes(span)
      return nil unless attributes

      transaction = attributes[Flare::TRANSACTION_NAME_ATTRIBUTE] if defined?(Flare::TRANSACTION_NAME_ATTRIBUTE)
      return transaction if transaction

      namespace = attributes["code.namespace"]
      function = attributes["code.function"]
      namespace && (function ? "#{namespace}##{function}" : namespace)
    end

    def route_for(controller, span)
      route = span_attributes(span)&.[]("http.route")
      return route.to_s if route

      request = controller.request if controller.respond_to?(:request)
      request.route_uri_pattern if request.respond_to?(:route_uri_pattern)
    rescue StandardError
      nil
    end

    def param_names_for(controller, context)
      params = context[:params]
      if params.nil? && controller.respond_to?(:request)
        params = controller.request.parameters
      end
      params = params.to_unsafe_h if params.respond_to?(:to_unsafe_h)
      ErrorSample.param_names(params)
    rescue StandardError
      []
    end

    def span_attributes(span)
      span.attributes if span.respond_to?(:attributes)
    end

    def current_span
      OpenTelemetry::Trace.current_span if defined?(OpenTelemetry::Trace)
    end

    def hex_trace_id(span)
      context = span&.context
      context.hex_trace_id if context.respond_to?(:valid?) && context.valid?
    end

    def warn_once(error)
      return if @warned_pid == $$

      @warned_pid = $$
      @logger.warn("[Flare::ErrorTracker] report failed: #{error.class}: #{error.message}")
    end

    # Rails.error subscriber. Rails 7.0 passes handled/severity/context;
    # 7.1+ adds source.
    class ReporterSubscriber
      def initialize(tracker)
        @tracker = tracker
      end

      def report(error, handled:, severity: nil, context: {}, source: nil, **)
        @tracker.report(error, handled: handled, context: context, source: source)
        nil
      end
    end

    # Prepended to the OTel SDK span so the exception object behind an
    # exception event is known when the span finishes.
    module SpanExceptionCapture
      def record_exception(exception, attributes: nil)
        tracker = ErrorTracker.current
        tracker.remember_span_exception(self, exception) if tracker&.enabled?
        super
      end
    end
  end
end
