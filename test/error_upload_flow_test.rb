# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "zlib"
require "concurrent/executor/immediate_executor"
require "rails"
require "flare"

# The sample upload contract with /api/rules and ingest, against stubbed HTTP:
# rules poll -> Flare-Error-Samples header -> error_uploads -> PUT to R2 ->
# POST /api/errors.
class ErrorUploadFlowTest < Minitest::Test
  class Transport
    attr_reader :calls

    def initialize
      @calls = []
      @responses = Hash.new { |h, k| h[k] = [] }
    end

    def queue(method, response)
      @responses[method] << response
    end

    def get(url, headers = {}) = record(:get, url, nil, headers)
    def put(url, body, headers = {}) = record(:put, url, body, headers)
    def post(url, body, headers = {}) = record(:post, url, body, headers)

    def of(method)
      @calls.select { |call| call[:method] == method }
    end

    private

    def record(method, url, body, headers)
      @calls << { method: method, url: url, body: body, headers: headers }
      @responses[method].shift || Flare::HttpTransport::Response.new(code: "200", body: "{}", headers: {})
    end
  end

  def setup
    @transport = Transport.new
    configuration = Flare::Configuration.new
    configuration.revision = "rev1"
    @uploader = Flare::ErrorUploader.new(
      notify_url: "https://flare.example/api/errors", api_key: "push_abc",
      project: "demo-app", environment: "production",
      transport: @transport, logger: Logger.new(IO::NULL)
    )
    @tracker = Flare::ErrorTracker.new(
      configuration: configuration, uploader: @uploader,
      executor: Concurrent::ImmediateExecutor.new, logger: Logger.new(IO::NULL)
    )
    @manager = Flare::RuleManager.new(
      sampler: Flare::Sampler.new, marker: Flare::Marker.new, pool: Flare::UploadUrlPool.new,
      error_tracker: @tracker, base_url: "https://flare.example", api_key: "push_abc",
      project: "demo-app", environment: "production",
      transport: @transport, logger: Logger.new(IO::NULL)
    )
  end

  def test_no_header_until_tracking_is_on_and_a_sample_waits
    @tracker.report(raised, handled: false)
    poll({ "trace_rules" => [], "error_tracking" => true }, etag: '"e1"')
    refute @transport.of(:get).last[:headers].key?("Flare-Error-Samples"), "the gate was off when it raised"

    poll({ "trace_rules" => [], "error_tracking" => true })
    refute @transport.of(:get).last[:headers].key?("Flare-Error-Samples")
    assert_equal '"e1"', @transport.of(:get).last[:headers]["If-None-Match"]
  end

  def test_old_server_without_the_flag_keeps_tracking_off
    poll({ "trace_rules" => [] })
    refute @tracker.enabled?
  end

  def test_304_keeps_the_gate
    poll({ "trace_rules" => [], "error_tracking" => true }, etag: '"e1"')
    @transport.queue(:get, Flare::HttpTransport::Response.new(code: "304", body: "", headers: {}))
    @manager.poll_now
    assert @tracker.enabled?
  end

  def test_sample_uploads_and_notifies
    poll({ "trace_rules" => [], "error_tracking" => true })
    error = raised
    @tracker.report(error, handled: false, context: { operation: "UsersController#show" })
    fingerprint = @tracker.sample_request.first
    key = "incoming/errors/env=7/fp=#{fingerprint}/11111111-1111-1111-1111-111111111111.json.gz"

    @transport.queue(:put, Flare::HttpTransport::Response.new(code: "200", body: "", headers: {}))
    @transport.queue(:post, Flare::HttpTransport::Response.new(code: "202", body: "", headers: {}))
    poll({
      "trace_rules" => [], "error_tracking" => true,
      "error_uploads" => [{ "fingerprint" => fingerprint, "upload_id" => "11111111-1111-1111-1111-111111111111",
                            "key" => key, "put_url" => "https://r2.example/put?sig=1",
                            "expires_at" => "2026-11-25T01:00:00Z" }]
    })

    assert_equal fingerprint, @transport.of(:get).last[:headers]["Flare-Error-Samples"]

    put = @transport.of(:put).last
    assert_equal "https://r2.example/put?sig=1", put[:url]
    assert_equal({ "Content-Type" => "application/json", "Content-Encoding" => "gzip" }, put[:headers])
    sample = JSON.parse(Zlib.gunzip(put[:body]))
    assert_equal fingerprint, sample["fingerprint"]
    assert_equal "RuntimeError", sample["class"]
    assert_equal "UsersController#show", sample["operation"]

    notify = @transport.of(:post).last
    assert_equal "https://flare.example/api/errors", notify[:url]
    assert_equal "Bearer push_abc", notify[:headers]["Authorization"]
    assert_equal "demo-app", notify[:headers]["Flare-Project"]
    assert_equal "production", notify[:headers]["Flare-Environment"]
    body = JSON.parse(notify[:body])
    assert_equal %w[upload_id fingerprint key occurred_at revision hex_trace_id], body.keys
    assert_equal "11111111-1111-1111-1111-111111111111", body["upload_id"]
    assert_equal fingerprint, body["fingerprint"]
    assert_equal key, body["key"]
    assert_equal "rev1", body["revision"]
    assert_equal sample["occurred_at"], body["occurred_at"]

    assert_equal 1, @tracker.upload_count.value
    poll({ "trace_rules" => [], "error_tracking" => true })
    refute @transport.of(:get).last[:headers].key?("Flare-Error-Samples")
  end

  def test_refused_fingerprint_is_not_asked_for_again
    poll({ "trace_rules" => [], "error_tracking" => true })
    @tracker.report(raised, handled: false)
    poll({ "trace_rules" => [], "error_tracking" => true, "error_uploads" => [] })

    assert @transport.of(:get).last[:headers].key?("Flare-Error-Samples")
    assert_empty @transport.of(:put)

    @tracker.report(raised, handled: false)
    poll({ "trace_rules" => [], "error_tracking" => true })
    refute @transport.of(:get).last[:headers].key?("Flare-Error-Samples")
  end

  def test_failed_put_skips_notify
    poll({ "trace_rules" => [], "error_tracking" => true })
    @tracker.report(raised, handled: false)
    fingerprint = @tracker.sample_request.first
    @transport.queue(:put, Flare::HttpTransport::Response.new(code: "403", body: "", headers: {}))
    poll({ "error_tracking" => true, "error_uploads" => [
      { "fingerprint" => fingerprint, "upload_id" => "u", "key" => "k", "put_url" => "https://r2.example/x" }
    ] })

    assert_equal 1, @transport.of(:put).size
    assert_empty @transport.of(:post)
    assert_equal 1, @uploader.put_failure_count.value
  end

  def test_failed_notify_is_counted
    sample = { fingerprint: "0123456789abcdef", json: "{}", occurred_at: "t", revision: nil, hex_trace_id: nil }
    @transport.queue(:put, Flare::HttpTransport::Response.new(code: "200", body: "", headers: {}))
    @transport.queue(:post, Flare::HttpTransport::Response.new(code: "500", body: "", headers: {}))

    refute @uploader.upload(sample, { upload_id: "u", key: "k", put_url: "https://r2.example/x" })
    assert_equal 1, @uploader.notify_failure_count.value
  end

  def test_turning_tracking_off_sends_nothing
    poll({ "trace_rules" => [], "error_tracking" => true })
    @tracker.report(raised, handled: false)
    poll({ "trace_rules" => [], "error_tracking" => false })
    poll({ "trace_rules" => [], "error_tracking" => false })

    refute @transport.of(:get).last[:headers].key?("Flare-Error-Samples")
    storage = Flare::MetricStorage.new
    @tracker.record(storage)
    assert storage.empty?
  end

  private

  def poll(payload, etag: nil)
    headers = etag ? { "etag" => etag } : {}
    @transport.queue(:get, Flare::HttpTransport::Response.new(code: "200", body: JSON.generate(payload), headers: headers))
    @manager.poll_now
  end

  def raised
    raise "boom"
  rescue => e
    e
  end
end
