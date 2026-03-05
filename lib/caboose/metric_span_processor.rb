# frozen_string_literal: true

require_relative "metric_key"

module Caboose
  # OpenTelemetry SpanProcessor that extracts metrics from spans.
  # Aggregates counts, durations, and error rates by namespace/service/target/operation.
  class MetricSpanProcessor
    # Standard OTel span kind symbols
    SERVER = :server
    CLIENT = :client
    CONSUMER = :consumer

    # Cache store class name patterns mapped to short service names
    CACHE_STORE_MAP = {
      "redis" => "redis",
      "mem_cache" => "memcache",
      "memcache" => "memcache",
      "dalli" => "memcache",
      "file" => "file",
      "memory" => "memory",
      "null" => "null",
      "solid_cache" => "solid_cache"
    }.freeze

    def initialize(storage:)
      @storage = storage
      @pid = $$
    end

    # Called when a span starts - no-op for metrics
    def on_start(span, parent_context); end

    # Called when a span ends - extract and record metrics.
    # OTel SDK 1.10+ calls on_finish; older versions call on_end.
    def on_finish(span)
      return unless span.end_timestamp && span.start_timestamp

      detect_forking

      if web_request?(span)
        record_web_metric(span)
      elsif background_job?(span)
        record_background_metric(span)
      elsif database_span?(span)
        record_db_metric(span)
      elsif http_client_span?(span)
        record_http_metric(span)
      elsif cache_span?(span)
        record_cache_metric(span)
      elsif view_span?(span)
        record_view_metric(span)
      end
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
        Caboose.log "Fork detected (was=#{@pid} now=#{$$}), restarting metrics flusher"
        @pid = $$
        Caboose.after_fork
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

    def record_web_metric(span)
      # Skip requests that never hit a Rails controller (assets, favicon, bot probes, etc.)
      # These have no code.namespace set by ActionPack instrumentation.
      return unless span.attributes["code.namespace"]

      key = MetricKey.new(
        bucket: bucket_time(span),
        namespace: "web",
        service: "rails",
        target: span.attributes["code.namespace"],
        operation: span.attributes["code.function"]
      )

      @storage.increment(
        key,
        duration_ms: duration_ms(span),
        error: http_error?(span)
      )
    end

    def record_background_metric(span)
      key = MetricKey.new(
        bucket: bucket_time(span),
        namespace: "job",
        service: extract_job_system(span),
        target: span.attributes["code.namespace"] || span.attributes["messaging.destination"] || "unknown",
        operation: span.attributes["code.function"] || span.name
      )

      @storage.increment(
        key,
        duration_ms: duration_ms(span),
        error: span_error?(span)
      )
    end

    def record_db_metric(span)
      db_system = span.attributes["db.system"].to_s

      key = MetricKey.new(
        bucket: bucket_time(span),
        namespace: "db",
        service: db_system,
        target: extract_db_target(span, db_system),
        operation: extract_db_operation(span, db_system)
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

      method = span.attributes["http.method"] ||
               span.attributes["http.request.method"] ||
               "UNKNOWN"

      key = MetricKey.new(
        bucket: bucket_time(span),
        namespace: "http",
        service: host.to_s.downcase,
        target: extract_http_path(span),
        operation: method.to_s.upcase
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

    def http_error?(span)
      status = span.attributes["http.status_code"] || span.attributes["http.response.status_code"]
      status.to_i >= 500
    end

    def span_error?(span)
      span.status&.code == OpenTelemetry::Trace::Status::ERROR
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

    def extract_db_target(span, db_system)
      case db_system
      when "redis"
        # For Redis, use db.redis.namespace if available, or the database index
        span.attributes["db.redis.database_index"]&.to_s ||
          span.attributes["db.name"] ||
          "default"
      else
        # For SQL databases, prefer table name from attributes or parsed from SQL
        span.attributes["db.sql.table"] ||
          extract_sql_table(span) ||
          span.attributes["db.name"] ||
          "unknown"
      end
    end

    def extract_db_operation(span, db_system)
      case db_system
      when "redis"
        span.attributes["db.operation"]&.to_s&.downcase ||
          span.name.to_s.split.last&.downcase ||
          "command"
      else
        span.attributes["db.operation"]&.to_s&.upcase ||
          extract_sql_operation(span) ||
          "query"
      end
    end

    def extract_sql_operation(span)
      statement = span.attributes["db.statement"]
      return nil unless statement

      # Extract first word (SELECT, INSERT, UPDATE, DELETE, etc.)
      statement.to_s.strip.split(/\s+/).first&.upcase
    end

    def extract_sql_table(span)
      statement = span.attributes["db.statement"]
      return nil unless statement

      sql = statement.to_s.strip

      case sql
      when /\bFROM\s+[`"]?(\w+)[`"]?/i
        $1
      when /\bINTO\s+[`"]?(\w+)[`"]?/i
        $1
      when /\bUPDATE\s+[`"]?(\w+)[`"]?/i
        $1
      end
    end

    def extract_host_from_url(span)
      url = span.attributes["http.url"] || span.attributes["url.full"]
      return nil unless url

      URI.parse(url.to_s).host
    rescue URI::InvalidURIError
      nil
    end

    def extract_http_path(span)
      path = span.attributes["http.target"] ||
             span.attributes["url.path"] ||
             extract_path_from_url(span)

      # Normalize path - remove query string, replace IDs with placeholders
      normalize_path(path&.to_s&.split("?")&.first || "/")
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
        when /\A[0-9a-f]{32,}\z/i
          # Long hex strings (tokens, hashes): -> :token
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
