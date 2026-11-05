# frozen_string_literal: true

require_relative "test_helper"
require "flare/trace_blob"
require "flare/sampler"
require "open3"
require "rbconfig"

class TraceBlobTest < Minitest::Test
  SpanData = Struct.new(:name, :span_id, :parent_span_id, :start_timestamp, :end_timestamp, :attributes, :kind, keyword_init: true)

  def test_to_h_emits_the_expected_top_level_shape
    raw_trace = "\xaa".b * 16
    spans = [
      span("rack.request", id: "\x01".b * 8, parent: nil,         start_ns: 0, end_ns: 100_000_000,
           attrs: { Flare::Sampler::RULE_ID_ATTRIBUTE => 9 }),
      span("controller.action", id: "\x02".b * 8, parent: "\x01".b * 8,
           start_ns: 5_000_000, end_ns: 90_000_000)
    ]

    h = Flare::TraceBlob.build(trace_id: raw_trace, spans: spans).to_h

    assert_equal raw_trace.unpack1("H*"), h["trace_id"]
    assert_equal "rack.request", h["root_name"]
    assert_equal 100, h["duration_ms"]
    assert_equal 9, h["trace_rule_id"]
    assert h["started_at"].match?(/\A1970-01-01T00:00:00/)
    assert_equal 2, h["spans"].length
  end

  def test_root_has_nil_parent_id_and_children_keep_theirs
    spans = [
      span("root", id: "\x01".b * 8, parent: nil, start_ns: 0, end_ns: 10_000_000),
      span("child", id: "\x02".b * 8, parent: "\x01".b * 8, start_ns: 1_000_000, end_ns: 5_000_000)
    ]

    h = Flare::TraceBlob.build(trace_id: ("\x01".b * 16), spans: spans).to_h
    root_h, child_h = h["spans"]

    assert_nil root_h["parent_id"]
    assert_equal "01" * 8, child_h["parent_id"]
  end

  def test_treats_zero_parent_id_as_root
    spans = [
      span("root", id: "\x01".b * 8, parent: ("\x00".b * 8), start_ns: 0, end_ns: 10_000_000)
    ]

    h = Flare::TraceBlob.build(trace_id: ("\x01".b * 16), spans: spans).to_h
    assert_nil h["spans"].first["parent_id"]
  end

  def test_rule_id_read_from_any_span_with_the_attribute
    spans = [
      span("root", id: "\x01".b * 8, parent: nil, start_ns: 0, end_ns: 10_000_000),
      span("inner", id: "\x02".b * 8, parent: "\x01".b * 8,
           start_ns: 1_000_000, end_ns: 5_000_000,
           attrs: { Flare::Sampler::RULE_ID_ATTRIBUTE => 42 })
    ]

    h = Flare::TraceBlob.build(trace_id: ("\x01".b * 16), spans: spans).to_h
    assert_equal 42, h["trace_rule_id"]
  end

  def test_root_name_is_truncated_to_server_limit
    spans = [
      span("x" * 300, id: "\x01".b * 8, parent: nil, start_ns: 0, end_ns: 10_000_000)
    ]

    h = Flare::TraceBlob.build(trace_id: ("\x01".b * 16), spans: spans).to_h

    assert_equal 255, h["root_name"].length
  end

  def test_remote_parented_entry_span_is_used_as_the_root_summary
    remote_parent_id = "\x99".b * 8
    spans = [
      span("SELECT users", id: "\x02".b * 8, parent: "\x01".b * 8,
           start_ns: 5_000_000, end_ns: 10_000_000, kind: :client),
      span("UsersController#show", id: "\x01".b * 8, parent: remote_parent_id,
           start_ns: 0, end_ns: 100_000_000,
           attrs: { Flare::Sampler::RULE_ID_ATTRIBUTE => 9 },
           kind: :server)
    ]

    h = Flare::TraceBlob.build(trace_id: ("\xaa".b * 16), spans: spans).to_h

    assert_equal "UsersController#show", h["root_name"]
    assert_equal 100, h["duration_ms"]
  end

  def test_invalid_utf8_is_replaced_so_the_blob_serializes
    spans = [
      span("GET /caf\xC3\xA9".b, id: "\x01".b * 8, parent: nil, start_ns: 0, end_ns: 10_000_000,
           attrs: { "user_agent.original" => "curl\xFF".b, "db.statement" => "SELECT '\xC3'", "tags" => ["ok", "\xFF".b], "app.\xFF".b => 1 },
           kind: :server)
    ]

    json = JSON.generate(Flare::TraceBlob.build(trace_id: ("\x01".b * 16), spans: spans).to_h)
    h = JSON.parse(json)
    attrs = h["spans"].first["attributes"]

    assert_equal "GET /caf\u00e9", h["root_name"]
    assert_equal "GET /caf\u00e9", h["spans"].first["name"]
    assert_equal "curl\uFFFD", attrs["user_agent.original"]
    assert_equal "SELECT ?", attrs["db.statement"]
    assert_equal ["ok", "\uFFFD"], attrs["tags"]
    assert_equal 1, attrs["app.\uFFFD"]
  end

  def test_filters_params_and_masks_sql_in_names_and_attributes
    attrs = {
      "url.query" => "password=hunter2&page=2",
      "http.url" => "https://user:pw@api.example.com/items?api_key=abc&page=2#frag",
      "db.system" => "postgresql",
      "db.statement" => %q{SELECT "users".* FROM "users" WHERE token = 'abc' AND id = 42},
      "code.namespace" => "UsersController",
      "to" => "someone@example.com",
      "subject" => "Your code is 1234",
      "password" => "hunter2",
      Flare::Sampler::RULE_ID_ATTRIBUTE => 9
    }
    spans = [span("GET /x?token=abc", id: "\x01".b * 8, parent: nil, start_ns: 0, end_ns: 1, attrs: attrs, kind: :server)]

    h = Flare::TraceBlob.build(trace_id: "\x01".b * 16, spans: spans).to_h
    exported = h["spans"].first

    assert_equal "GET /x?token=[FILTERED]", h["root_name"]
    assert_equal "GET /x?token=[FILTERED]", exported["name"]
    assert_equal({
      "url.query" => "password=[FILTERED]&page=2",
      "http.url" => "https://api.example.com/items?api_key=[FILTERED]&page=2",
      "db.system" => "postgresql",
      "db.statement" => 'SELECT "users".* FROM "users" WHERE token = ? AND id = ?',
      "code.namespace" => "UsersController",
      "to" => "[FILTERED]",
      "subject" => "[FILTERED]",
      "password" => "[FILTERED]",
      Flare::Sampler::RULE_ID_ATTRIBUTE => 9
    }, exported["attributes"])
    assert_equal 9, h["trace_rule_id"]
  end

  def test_uses_the_apps_filter_parameters_including_ones_added_after_boot
    script = <<~RUBY
      require "rails"
      require "action_controller/railtie"
      $LOAD_PATH.unshift #{File.expand_path("../lib", __dir__).inspect}
      require "flare/sampler"
      require "flare/trace_blob"

      class App < Rails::Application
        config.root = Dir.pwd
        config.eager_load = false
        config.secret_key_base = "x" * 32
        config.logger = Logger.new(File::NULL)
        config.filter_parameters += [:zipcode]
      end
      App.initialize!

      Span = Struct.new(:name, :span_id, :parent_span_id, :start_timestamp, :end_timestamp, :attributes, :kind, keyword_init: true)
      export = lambda do
        span = Span.new(name: "GET", span_id: "a".b * 8, start_timestamp: 0, end_timestamp: 1, kind: :server,
          attributes: { "url.query" => "zipcode=1&plan=2&page=3" })
        puts Flare::TraceBlob.build(trace_id: "a".b * 16, spans: [span]).to_h["spans"].first["attributes"]["url.query"]
      end

      export.call
      Rails.application.config.filter_parameters << :plan
      export.call
    RUBY

    output, status = Dir.mktmpdir { |dir| Open3.capture2e(RbConfig.ruby, "-e", script, chdir: dir) }

    assert status.success?, output
    assert_equal ["zipcode=[FILTERED]&plan=2&page=3", "zipcode=[FILTERED]&plan=[FILTERED]&page=3"], output.lines.map(&:chomp).last(2)
  end

  def test_returns_nil_when_no_spans
    assert_nil Flare::TraceBlob.build(trace_id: "x", spans: [])
    assert_nil Flare::TraceBlob.build(trace_id: "x", spans: nil)
  end

  private

  def span(name, id:, parent:, start_ns:, end_ns:, attrs: nil, kind: :internal)
    SpanData.new(name: name, span_id: id, parent_span_id: parent,
                 start_timestamp: start_ns, end_timestamp: end_ns,
                 attributes: attrs, kind: kind)
  end
end
