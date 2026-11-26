# frozen_string_literal: true

require "active_support/inflector/methods"
require_relative "metric_key"
require_relative "slo_manager"
require_relative "http_metrics_config"
require_relative "sql_mask"
require_relative "store_statement"

module Flare
  TRANSACTION_NAME_ATTRIBUTE = "flare.transaction_name" unless const_defined?(:TRANSACTION_NAME_ATTRIBUTE)

  # OpenTelemetry SpanProcessor that extracts metrics from spans.
  # Aggregates counts, durations, and error rates by namespace/service/target/operation.
  class MetricSpanProcessor
    MAX_METRIC_STATEMENT_BYTES = 4_096

    # Standard OTel span kind symbols
    SERVER = :server
    CLIENT = :client
    CONSUMER = :consumer

    # Cache store name patterns mapped to short service names. Patterns are
    # matched against the downcased store name, which is usually a class name
    # with no underscores (SolidCache::Store is "solidcache::store").
    CACHE_STORE_MAP = {
      "redis" => "redis",
      "mem_cache" => "memcache",
      "memcache" => "memcache",
      "dalli" => "memcache",
      "file" => "file",
      "memory" => "memory",
      "null" => "null",
      "solid_cache" => "solid_cache",
      "solidcache" => "solid_cache"
    }.freeze

    ACTIVE_JOB_ERROR_STATUS = /\AUnexpected ActiveJob Error (\S+)\z/

    # Where a statement names the table it writes, by its first word. Every
    # other statement is named for the table it reads FROM.
    INTO_TABLE = /\bINTO\s+[`"]?(\w+)[`"]?/i
    WRITE_TABLES = {
      "INSERT" => INTO_TABLE,
      "REPLACE" => INTO_TABLE,
      "MERGE" => INTO_TABLE,
      "UPDATE" => /\bUPDATE\s+[`"]?(\w+)[`"]?/i
    }.freeze
    READ_TABLE = /\bFROM\s+[`"]?(\w+)[`"]?/i

    def initialize(storage:, http_metrics_config: nil, ignore_errors: nil, slo_manager: nil, error_tracker: nil)
      @storage = storage
      @error_tracker = error_tracker
      @http_metrics_config = http_metrics_config || HttpMetricsConfig::DEFAULT
      @ignore_errors = ignore_errors || []
      @slo_manager = slo_manager || SloManager.new
      @pid = $$
    end

    # Called when a span starts - no-op for metrics
    def on_start(span, parent_context); end

    # Called when a span ends - extract and record metrics.
    # OTel SDK 1.10+ calls on_finish; older versions call on_end.
    def on_finish(span)
      return unless span.end_timestamp && span.start_timestamp

      detect_forking

      if web_request?(span) || background_job?(span)
        record_entry_point_metric(span)
      elsif database_span?(span)
        record_db_metric(span)
      elsif http_client_span?(span)
        record_http_metric(span)
      elsif cache_span?(span)
        record_cache_metric(span)
      elsif view_span?(span)
        record_view_metric(span)
      end
    rescue StandardError => e
      # The SDK calls processors without a rescue, so a bug here would raise
      # into the app's request or job. Warn once per process so it can't
      # flood the logs (keyed by pid so forked workers still warn).
      return if @on_finish_error_warned_pid == $$

      @on_finish_error_warned_pid = $$
      warn "[Flare::MetricSpanProcessor] on_finish failed: #{e.class}: #{e.message}"
    end

    # "error" or "slow" when a web request or job fails its operation's
    # latency SLO, nil otherwise (including spans that are neither). It uses
    # the same keys, thresholds and error rules as error_count and
    # slow_count, so FilteringSpanProcessor keeps exactly the requests a
    # failures-only trace rule's SLO counts as failing.
    def slo_failure(span)
      key, error = entry_point(span)
      return nil unless key
      return "error" if error

      "slow" if slow?(key, duration_ms(span), error)
    end

    def force_flush(timeout: nil)
      OpenTelemetry::SDK::Trace::Export::SUCCESS
    end

    alias_method :on_end, :on_finish

    def shutdown(timeout: nil)
      OpenTelemetry::SDK::Trace::Export::SUCCESS
    end

    private

    # Detect forking (Puma workers, Passenger, etc.) and restart the
    # metrics flusher whose timer thread died during fork.
    # Called on every span end — the same pattern Flipper uses in record().
    def detect_forking
      if @pid != $$
        Flare.log "Fork detected (was=#{@pid} now=#{$$}), restarting metrics flusher"
        @pid = $$
        Flare.after_fork
      end
    end

    # Web requests: any server span (entry point for this service).
    # Server spans may have a remote parent from distributed trace propagation
    # (e.g., traceparent header), but they still represent the web request
    # handled by this application.
    def web_request?(span)
      span.kind == SERVER
    end

    # Background jobs: root consumer spans (ActiveJob, Sidekiq)
    def background_job?(span)
      span.kind == CONSUMER && root_span?(span)
    end

    # Database spans: any span with db.system attribute
    def database_span?(span)
      span.attributes["db.system"]
    end

    # HTTP client spans: client spans with http.method or http.request.method
    def http_client_span?(span)
      span.kind == CLIENT &&
        (span.attributes["http.method"] || span.attributes["http.request.method"])
    end

    # Cache spans: ActiveSupport cache notification spans
    def cache_span?(span)
      name = span.name.to_s
      name.start_with?("cache_") && name.end_with?(".active_support")
    end

    # View spans: ActionView render notification spans
    def view_span?(span)
      name = span.name.to_s
      name.start_with?("render_") && name.end_with?(".action_view")
    end

    def root_span?(span)
      span.parent_span_id.nil? ||
        span.parent_span_id == OpenTelemetry::Trace::INVALID_SPAN_ID
    end

    # Web and job entry points also count toward the latency SLO: slow means
    # over the operation's threshold without erroring.
    def record_entry_point_metric(span)
      key, error = entry_point(span)
      return unless key

      duration = duration_ms(span)
      @storage.increment(key, duration_ms: duration, error: error, slow: slow?(key, duration, error))
      @error_tracker&.entry_span_finished(span, operation: key.target, error: error)
    end

    # [metric key, error?] for a web request or job span, nil for anything
    # else and for requests that never reached a controller.
    def entry_point(span)
      if web_request?(span)
        key = web_key(span)
        [key, http_error?(span)] if key
      elsif background_job?(span)
        [job_key(span), span_error?(span)]
      end
    end

    def web_key(span)
      target = span.attributes[Flare::TRANSACTION_NAME_ATTRIBUTE]

      unless target
        # Skip requests that never hit a Rails controller (assets, favicon, bot probes, etc.)
        # These have no code.namespace set by ActionPack instrumentation.
        return unless span.attributes["code.namespace"]

        controller = span.attributes["code.namespace"]
        action = span.attributes["code.function"]
        target = action ? "#{controller}##{action}" : controller
      end

      MetricKey.new(
        bucket: bucket_time(span),
        namespace: "web",
        service: "rails",
        target: target,
        operation: http_status_class(span)
      )
    end

    def job_key(span)
      transaction_name = span.attributes[Flare::TRANSACTION_NAME_ATTRIBUTE]

      MetricKey.new(
        bucket: bucket_time(span),
        namespace: "job",
        service: extract_job_system(span),
        target: transaction_name || span.attributes["code.namespace"] || span.attributes["messaging.sidekiq.job_class"] || span.attributes["messaging.destination"] || "unknown",
        operation: transaction_name ? "perform" : (span.attributes["code.function"] || span.name)
      )
    end

    def slow?(key, duration_ms, error)
      @slo_manager.slow?(namespace: key.namespace, service: key.service, target: key.target,
                         duration_ms: duration_ms, error: error)
    end

    def record_db_metric(span)
      db_system = span.attributes["db.system"].to_s
      # Read the table and operation from the statement without its values, so
      # the words in a string literal can't become the metric's name. This runs on
      # the request thread and needs only the start of a statement, and a literal
      # the cut lands in is masked like any unterminated one.
      raw_statement = span.attributes["db.statement"]
      if raw_statement && SqlMask.sql_system?(db_system)
        statement = SqlMask.mask(raw_statement.to_s.byteslice(0, MAX_METRIC_STATEMENT_BYTES), db_system)
      end

      key = MetricKey.new(
        bucket: bucket_time(span),
        namespace: "db",
        service: db_system,
        target: extract_db_target(span, db_system, statement),
        operation: extract_db_operation(span, db_system, statement)
      )

      @storage.increment(
        key,
        duration_ms: duration_ms(span),
        error: span_error?(span)
      )
    end

    def record_http_metric(span)
      host = span.attributes["http.host"] ||
             span.attributes["server.address"] ||
             span.attributes["net.peer.name"] ||
             extract_host_from_url(span) ||
             "unknown"
      host = host.to_s.sub(/\A.*@/m, "").downcase

      method = span.attributes["http.method"] ||
               span.attributes["http.request.method"] ||
               "UNKNOWN"

      path = resolve_http_path(span, host)

      key = MetricKey.new(
        bucket: bucket_time(span),
        namespace: "http",
        service: host,
        target: "#{method.to_s.upcase} #{path}",
        operation: http_status_class(span)
      )

      @storage.increment(
        key,
        duration_ms: duration_ms(span),
        error: http_error?(span)
      )
    end

    def record_cache_metric(span)
      operation = extract_cache_operation(span)

      key = MetricKey.new(
        bucket: bucket_time(span),
        namespace: "cache",
        service: extract_cache_store(span),
        target: operation,
        operation: operation
      )

      @storage.increment(
        key,
        duration_ms: duration_ms(span),
        error: span_error?(span)
      )
    end

    def record_view_metric(span)
      key = MetricKey.new(
        bucket: bucket_time(span),
        namespace: "view",
        service: "actionview",
        target: extract_view_template(span),
        operation: extract_view_operation(span)
      )

      @storage.increment(
        key,
        duration_ms: duration_ms(span),
        error: span_error?(span)
      )
    end

    def bucket_time(span)
      # Use span start time, truncated to minute (in UTC for consistent bucketing)
      time = Time.at(span.start_timestamp / 1_000_000_000.0).utc
      Time.utc(time.year, time.month, time.day, time.hour, time.min, 0)
    end

    def duration_ms(span)
      ((span.end_timestamp - span.start_timestamp) / 1_000_000.0).round
    end

    # A 5xx is an error. So is a request that raised before any response
    # (a timeout, a dropped connection): it has no status code, only an error
    # span status. 4xx responses also carry an error span status, so the
    # span status only counts when there was no response at all.
    def http_error?(span)
      status = span.attributes["http.status_code"] || span.attributes["http.response.status_code"]
      code = status.to_i
      return span_error?(span) if code.zero?

      code >= 500 && !ignored_exception?(span)
    end

    def http_status_class(span)
      status = span.attributes["http.status_code"] || span.attributes["http.response.status_code"]
      code = status.to_i
      if code >= 500 then "5xx"
      elsif code >= 400 then "4xx"
      elsif code >= 300 then "3xx"
      elsif code >= 200 then "2xx"
      elsif code >= 100 then "1xx"
      else "unknown"
      end
    end

    def span_error?(span)
      return false if span.status&.code != OpenTelemetry::Trace::Status::ERROR

      !ignored_exception?(span)
    end

    def ignored_exception?(span)
      return false if @ignore_errors.empty?

      type = exception_type(span)
      !type.nil? && ignored_exception_type?(type)
    end

    def exception_type(span)
      self.class.exception_type(span)
    end

    # A job's retried exception is recorded on its enqueue_retry child span,
    # so the process span only names it in the status description.
    def self.exception_type(span)
      event = span.events&.reverse_each&.find { |e| e.name == "exception" }
      event&.attributes&.[]("exception.type") ||
        span.status&.description.to_s[ACTIVE_JOB_ERROR_STATUS, 1]
    end

    # Subclasses of an ignored class match when the class is loaded.
    def ignored_exception_type?(type)
      klass = ActiveSupport::Inflector.safe_constantize(type)
      names = klass.is_a?(Class) ? klass.ancestors.map(&:name) : [type]
      names.any? { |name| @ignore_errors.include?(name) }
    end

    def extract_job_system(span)
      # Detect job system from span attributes
      if span.attributes["messaging.system"]
        span.attributes["messaging.system"].to_s
      elsif span.name.to_s.include?("sidekiq")
        "sidekiq"
      elsif span.name.to_s.include?("ActiveJob")
        "activejob"
      else
        "background"
      end
    end

    def extract_db_target(span, db_system, statement)
      if StoreStatement.redis_system?(db_system)
        # For Redis, use db.redis.namespace if available, or the database index
        span.attributes["db.redis.database_index"]&.to_s ||
          span.attributes["db.name"] ||
          "default"
      else
        # Prefer the table name from attributes. Only SQL statements are parsed
        # for one; statement is nil for anything else.
        span.attributes["db.sql.table"] ||
          span.attributes["db.mongodb.collection"] ||
          span.attributes["db.collection.name"] ||
          extract_sql_table(statement) ||
          span.attributes["db.name"] ||
          "unknown"
      end
    end

    def extract_db_operation(span, db_system, statement)
      operation = SqlMask.operation_word(span.attributes["db.operation"])

      if StoreStatement.redis_system?(db_system)
        (operation || SqlMask.operation_word(span.name.to_s.split.last))&.downcase || "query"
      else
        # The first word of a masked statement (SELECT, INSERT, UPDATE, etc.)
        word = statement ? first_word(statement) : SqlMask.command_word(span.attributes["db.statement"])
        (operation || word)&.upcase || "query"
      end
    end

    # The table the statement works on: an INSERT's INTO, an UPDATE's own
    # table, otherwise the first FROM outside parentheses, so an upsert's
    # "IS NOT DISTINCT FROM excluded.x" or a subquery in the select list can't
    # name it. With no FROM outside parentheses (SELECT COUNT(*) FROM
    # (SELECT ...)), and for a WITH, the first one anywhere counts.
    def extract_sql_table(statement)
      return nil unless statement

      word = first_word(statement)&.upcase
      pattern = WRITE_TABLES.fetch(word, READ_TABLE)
      return statement[pattern, 1] if word == "WITH"

      scanner = StringScanner.new(statement)
      first = nil
      depth = 0
      counted = 0
      while scanner.skip_until(pattern)
        # Masked SQL has no parentheses inside values. Count only the text
        # since the last match, so a long statement is read once.
        between = statement.byteslice(counted, scanner.pos - scanner.matched_size - counted)
        depth += between.count("(") - between.count(")")
        return scanner[1] if depth <= 0

        first ||= scanner[1]
        counted = scanner.pos
      end
      first
    end

    def first_word(statement)
      statement[/\S+/]
    end

    def extract_host_from_url(span)
      url = span.attributes["http.url"] || span.attributes["url.full"]
      return nil unless url

      URI.parse(url.to_s).host
    rescue URI::InvalidURIError
      nil
    end

    # Resolve the HTTP path using the http_metrics_config.
    # Returns the resolved path string (could be "*", a custom string, or normalized path).
    def resolve_http_path(span, host)
      raw_path = raw_http_path(span)
      result = @http_metrics_config.resolve(host, raw_path)

      if result == "*"
        "*"
      elsif result.is_a?(String)
        result
      else
        # nil means use normalize_path
        normalize_path(raw_path)
      end
    end

    def raw_http_path(span)
      path = span.attributes["http.target"] ||
             span.attributes["url.path"] ||
             extract_path_from_url(span)
      path&.to_s&.split(/[?#]/)&.first || "/"
    end

    # Normalize URL paths to prevent cardinality explosion.
    # Replaces numeric IDs, UUIDs, and other high-cardinality segments with placeholders.
    def normalize_path(path)
      return "/" if path.nil? || path.empty?

      segments = path.split("/")
      normalized = segments.map do |segment|
        next segment if segment.empty?

        case segment
        when /\A\d+\z/
          # Pure numeric ID: /users/123 -> /users/:id
          ":id"
        when /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
          # UUID: /posts/550e8400-e29b-41d4-a716-446655440000 -> /posts/:uuid
          ":uuid"
        when /\A[0-9a-f]{24}\z/i
          # MongoDB ObjectId: /items/507f1f77bcf86cd799439011 -> /items/:id
          ":id"
        when /\A[0-9a-f]{32,}\z/i, /[^@]@/
          # Long hex strings (tokens, hashes), or anything shaped like user@host: -> :token
          ":token"
        else
          segment
        end
      end

      result = normalized.join("/")
      result.empty? ? "/" : result
    end

    def extract_path_from_url(span)
      url = span.attributes["http.url"] || span.attributes["url.full"]
      return nil unless url

      URI.parse(url.to_s).path
    rescue URI::InvalidURIError
      nil
    end

    def extract_cache_store(span)
      store = span.attributes["store"].to_s
      return "unknown" if store.empty?

      downcased = store.downcase
      CACHE_STORE_MAP.each do |pattern, name|
        return name if downcased.include?(pattern)
      end

      # Fallback: last segment, strip Store/Cache suffixes
      short = store.split("::").last
                   .gsub(/CacheStore$|Store$|Cache$/, "")
                   .downcase
      short.empty? ? "unknown" : short
    end

    def extract_cache_operation(span)
      base_op = span.name.to_s
                    .delete_prefix("cache_")
                    .delete_suffix(".active_support")

      case base_op
      when "read"
        span.attributes["hit"] == true ? "read.hit" : "read.miss"
      when "exist?"
        span.attributes["exist"] == true ? "exist.hit" : "exist.miss"
      else
        base_op
      end
    end

    def extract_view_template(span)
      identifier = span.attributes["identifier"]
      return span.attributes["code.filepath"] || "unknown" unless identifier

      path = identifier.to_s
      if (idx = path.index("app/views/"))
        path[(idx + "app/views/".length)..]
      elsif (idx = path.index("app/"))
        path[(idx + "app/".length)..]
      else
        File.basename(path)
      end
    end

    def extract_view_operation(span)
      span.name.to_s
          .delete_prefix("render_")
          .delete_suffix(".action_view")
    end
  end
end
