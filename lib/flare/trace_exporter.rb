# frozen_string_literal: true

require "json"
require "zlib"
require "stringio"
require "logger"
require "uri"
require "concurrent/atomic/atomic_fixnum"
require "opentelemetry/sdk"

require_relative "sampler"
require_relative "trace_blob"
require_relative "http_transport"

module Flare
  # Custom OTel exporter. For each batch FilteringSpanProcessor hands over:
  #
  #   1. Group spans by trace_id.
  #   2. For each trace, build a Flare::TraceBlob and gzip-JSON-encode it.
  #   3. Check out a presigned R2 PUT URL from UploadUrlPool.
  #   4. PUT the gzipped body straight to R2 -- Flare's server is NOT in
  #      the trace-bytes path.
  #   5. After R2 returns 200, POST /api/traces { key } using the
  #      customer's push token + Flare-Project / Flare-Environment headers.
  #      That's the self-notify hop the design swapped in for the CF Worker.
  #
  # 403 from R2 means the presigned URL expired between issue and use;
  # discard, check out the next URL, retry once. Pool empty -> FAILURE.
  # Notify-POST failure is logged + counted but doesn't fail the export
  # (the blob is in R2, just won't be processed; incoming/* lifecycle
  # cleans it up in 1hr).
  class TraceExporter
    SUCCESS = OpenTelemetry::SDK::Trace::Export::SUCCESS
    FAILURE = OpenTelemetry::SDK::Trace::Export::FAILURE

    PUT_HEADERS = {
      "Content-Type"     => "application/json",
      "Content-Encoding" => "gzip"
    }.freeze

    attr_reader :put_failure_count, :notify_failure_count, :pool_empty_count, :exception_count

    def initialize(pool:, notify_url:, api_key:, project:, environment:,
                   transport: nil, logger: nil)
      @pool         = pool
      @notify_url   = notify_url.to_s
      @api_key      = api_key
      @project      = project
      @environment  = environment
      @transport    = transport || HttpTransport.new
      @logger       = logger || Logger.new($stderr, level: Logger::WARN)

      @put_failure_count    = Concurrent::AtomicFixnum.new(0)
      @notify_failure_count = Concurrent::AtomicFixnum.new(0)
      @pool_empty_count     = Concurrent::AtomicFixnum.new(0)
      @exception_count      = Concurrent::AtomicFixnum.new(0)
    end

    def export(spans, timeout: nil)
      grouped = spans.group_by(&:trace_id)
      return SUCCESS if grouped.empty?

      overall = SUCCESS
      grouped.each do |trace_id, group|
        result = ship(TraceBlob.build(trace_id: trace_id, spans: group))
        overall = FAILURE if result == FAILURE
      end
      overall
    rescue StandardError => e
      @exception_count.increment
      @logger.warn("[Flare::TraceExporter] export raised: #{e.class}: #{e.message}")
      FAILURE
    end

    def force_flush(timeout: nil)
      SUCCESS
    end

    def shutdown(timeout: nil)
      SUCCESS
    end

    private

    def ship(blob, retried: false)
      return FAILURE if blob.nil?

      entry = @pool.checkout
      if entry.nil?
        @pool_empty_count.increment
        return FAILURE
      end

      body = gzip(JSON.generate(blob.to_h))
      response = @transport.put(entry[:put_url], body, PUT_HEADERS)

      case response.code
      when "200", "204"
        notify(entry[:key])
        SUCCESS
      when "403"
        # Presigned URL probably expired; try once more with the next one.
        retried ? record_put_failure(response) : ship(blob, retried: true)
      else
        record_put_failure(response)
      end
    end

    def notify(key)
      response = @transport.post(@notify_url, JSON.generate(key: key), notify_headers)
      return if response.code == "202"

      @notify_failure_count.increment
      @logger.warn("[Flare::TraceExporter] notify failed: HTTP #{response.code}")
    rescue StandardError => e
      @notify_failure_count.increment
      @logger.warn("[Flare::TraceExporter] notify exception: #{e.class}: #{e.message}")
    end

    def notify_headers
      {
        "Content-Type"      => "application/json",
        "Authorization"     => "Bearer #{@api_key}",
        "Flare-Project"     => @project,
        "Flare-Environment" => @environment
      }
    end

    def record_put_failure(response)
      @put_failure_count.increment
      @logger.warn("[Flare::TraceExporter] PUT failed: HTTP #{response.code}")
      FAILURE
    end

    def gzip(body)
      io = StringIO.new
      gz = Zlib::GzipWriter.new(io)
      gz.write(body)
      gz.close
      io.string
    end
  end
end
