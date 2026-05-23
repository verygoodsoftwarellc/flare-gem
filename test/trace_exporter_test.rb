# frozen_string_literal: true

require_relative "test_helper"
require "flare/upload_url_pool"
require "flare/trace_exporter"

class TraceExporterTest < Minitest::Test
  SUCCESS = OpenTelemetry::SDK::Trace::Export::SUCCESS
  FAILURE = OpenTelemetry::SDK::Trace::Export::FAILURE

  SpanData = Struct.new(:name, :trace_id, :span_id, :parent_span_id,
                        :start_timestamp, :end_timestamp, :attributes, keyword_init: true)

  def setup
    @pool      = Flare::UploadUrlPool.new
    @transport = RecordingTransport.new
    @exporter  = Flare::TraceExporter.new(
      pool:        @pool,
      notify_url:  "https://flare.example/api/traces",
      api_key:     "push_abc",
      project:     "demo-app",
      environment: "production",
      transport:   @transport,
      logger:      Logger.new(IO::NULL)
    )
  end

  def test_happy_path_puts_to_r2_then_notifies_and_returns_success
    @pool.replace([upload("u1")])
    @transport.responses_for(:put)  << http(200)
    @transport.responses_for(:post) << http(202)

    result = @exporter.export([span("a", trace: "t1")])

    assert_equal SUCCESS, result
    assert_equal 1, @transport.calls(:put).length
    assert_equal 1, @transport.calls(:post).length

    put_call = @transport.calls(:put).first
    assert_equal "https://r2/put/u1", put_call[:url]
    assert_equal "gzip", put_call[:headers]["Content-Encoding"]

    post_call = @transport.calls(:post).first
    assert_equal "https://flare.example/api/traces", post_call[:url]
    body = JSON.parse(post_call[:body])
    assert_equal "incoming/env=1/u1.json.gz", body["key"]
    assert_equal "Bearer push_abc", post_call[:headers]["Authorization"]
    assert_equal "demo-app",       post_call[:headers]["Flare-Project"]
    assert_equal "production",     post_call[:headers]["Flare-Environment"]
  end

  def test_groups_spans_by_trace_and_ships_each
    @pool.replace([upload("u1"), upload("u2")])
    2.times { @transport.responses_for(:put)  << http(200) }
    2.times { @transport.responses_for(:post) << http(202) }

    @exporter.export([
      span("a", trace: "t1"),
      span("b", trace: "t1"),
      span("c", trace: "t2")
    ])

    assert_equal 2, @transport.calls(:put).length
    assert_equal 2, @transport.calls(:post).length
  end

  def test_403_from_r2_retries_once_with_next_url
    @pool.replace([upload("u1"), upload("u2")])
    @transport.responses_for(:put)  << http(403) << http(200)
    @transport.responses_for(:post) << http(202)

    result = @exporter.export([span("a", trace: "t1")])

    assert_equal SUCCESS, result
    assert_equal 2, @transport.calls(:put).length
    assert_equal "https://r2/put/u2", @transport.calls(:put).last[:url]
  end

  def test_403_on_retry_records_put_failure_and_returns_failure
    @pool.replace([upload("u1"), upload("u2")])
    @transport.responses_for(:put) << http(403) << http(403)

    result = @exporter.export([span("a", trace: "t1")])

    assert_equal FAILURE, result
    assert_equal 1, @exporter.put_failure_count.value
    assert_equal 0, @transport.calls(:post).length
  end

  def test_empty_pool_returns_failure_and_increments_counter
    result = @exporter.export([span("a", trace: "t1")])
    assert_equal FAILURE, result
    assert_equal 1, @exporter.pool_empty_count.value
    assert_equal 0, @transport.calls(:put).length
  end

  def test_notify_failure_does_not_fail_the_export
    @pool.replace([upload("u1")])
    @transport.responses_for(:put)  << http(200)
    @transport.responses_for(:post) << http(500)

    result = @exporter.export([span("a", trace: "t1")])

    assert_equal SUCCESS, result
    assert_equal 1, @exporter.notify_failure_count.value
  end

  def test_handles_no_spans_as_success
    assert_equal SUCCESS, @exporter.export([])
  end

  def test_force_flush_and_shutdown_succeed
    assert_equal SUCCESS, @exporter.force_flush
    assert_equal SUCCESS, @exporter.shutdown
  end

  private

  def span(suffix, trace:)
    SpanData.new(
      name: "span-#{suffix}",
      trace_id: trace,
      span_id: "span-#{suffix}",
      parent_span_id: nil,
      start_timestamp: 0,
      end_timestamp: 10_000_000,
      attributes: {}
    )
  end

  def upload(id, expires_at: Time.now + 60)
    {
      upload_id:  id,
      key:        "incoming/env=1/#{id}.json.gz",
      put_url:    "https://r2/put/#{id}",
      expires_at: expires_at
    }
  end

  def http(code, body: "")
    Flare::HttpTransport::Response.new(code: code.to_s, body: body)
  end

  class RecordingTransport
    def initialize
      @responses = Hash.new { |h, k| h[k] = [] }
      @calls     = Hash.new { |h, k| h[k] = [] }
    end

    def put(url, body, headers)
      record(:put, url, body, headers)
    end

    def post(url, body, headers)
      record(:post, url, body, headers)
    end

    def responses_for(method) = @responses[method]
    def calls(method)         = @calls[method]

    private

    def record(method, url, body, headers)
      @calls[method] << { url: url, body: body, headers: headers }
      @responses[method].shift || Flare::HttpTransport::Response.new(code: "200", body: "")
    end
  end
end
