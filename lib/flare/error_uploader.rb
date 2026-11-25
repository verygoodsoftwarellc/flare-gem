# frozen_string_literal: true

require "json"
require "logger"
require "concurrent/atomic/atomic_fixnum"

require_relative "client_headers"
require_relative "error_sample"
require_relative "http_transport"

module Flare
  # Uploads one error sample the way TraceExporter uploads a trace: PUT the
  # gzipped JSON to the presigned R2 URL from /api/rules, then
  # POST /api/errors so ingest picks it up.
  #
  # A failed PUT drops the sample (the URL was its quota). A failed notify
  # leaves the blob in incoming/, which expires after an hour.
  class ErrorUploader
    PUT_HEADERS = {
      "Content-Type"     => "application/json",
      "Content-Encoding" => "gzip"
    }.freeze

    attr_reader :put_failure_count, :notify_failure_count

    def initialize(notify_url:, api_key:, project:, environment:, transport: nil, logger: nil)
      @notify_url = notify_url.to_s
      @api_key = api_key
      @project = project
      @environment = environment
      @transport = transport || HttpTransport.new
      @logger = logger || Logger.new($stderr, level: Logger::WARN)
      @put_failure_count = Concurrent::AtomicFixnum.new(0)
      @notify_failure_count = Concurrent::AtomicFixnum.new(0)
    end

    # sample: { fingerprint:, json:, occurred_at:, revision:, hex_trace_id: }
    # entry:  { fingerprint:, upload_id:, key:, put_url:, expires_at: }
    # True once the sample is in R2 and ingest was told.
    def upload(sample, entry)
      response = @transport.put(entry[:put_url], ErrorSample.gzip(sample[:json]), PUT_HEADERS)
      unless %w[200 204].include?(response.code)
        @put_failure_count.increment
        @logger.warn("[Flare::ErrorUploader] PUT failed: HTTP #{response.code}")
        return false
      end

      notify(sample, entry)
    rescue StandardError => e
      @put_failure_count.increment
      @logger.warn("[Flare::ErrorUploader] upload raised: #{e.class}: #{e.message}")
      false
    end

    private

    def notify(sample, entry)
      body = JSON.generate(
        upload_id: entry[:upload_id],
        fingerprint: sample[:fingerprint],
        key: entry[:key],
        occurred_at: sample[:occurred_at],
        revision: sample[:revision],
        hex_trace_id: sample[:hex_trace_id]
      )
      response = @transport.post(@notify_url, body, notify_headers)
      return true if response.code.start_with?("2")

      @notify_failure_count.increment
      @logger.warn("[Flare::ErrorUploader] notify failed: HTTP #{response.code}")
      false
    rescue StandardError => e
      @notify_failure_count.increment
      @logger.warn("[Flare::ErrorUploader] notify raised: #{e.class}: #{e.message}")
      false
    end

    # Same identity as the trace notify. Never sent on the R2 PUT, where they
    # could break the signed-header set.
    def notify_headers
      ClientHeaders.to_h.merge(
        "Content-Type"      => "application/json",
        "Authorization"     => "Bearer #{@api_key}",
        "Flare-Project"     => @project,
        "Flare-Environment" => @environment
      )
    end
  end
end
