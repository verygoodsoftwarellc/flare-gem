# frozen_string_literal: true

require_relative "test_helper"
require "flare/trace_blob"
require "flare/sampler"

class TraceBlobTest < Minitest::Test
  SpanData = Struct.new(:name, :span_id, :parent_span_id, :start_timestamp, :end_timestamp, :attributes, keyword_init: true)

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

  def test_returns_nil_when_no_spans
    assert_nil Flare::TraceBlob.build(trace_id: "x", spans: [])
    assert_nil Flare::TraceBlob.build(trace_id: "x", spans: nil)
  end

  private

  def span(name, id:, parent:, start_ns:, end_ns:, attrs: nil)
    SpanData.new(name: name, span_id: id, parent_span_id: parent,
                 start_timestamp: start_ns, end_timestamp: end_ns,
                 attributes: attrs)
  end
end
