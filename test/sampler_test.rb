# frozen_string_literal: true

require_relative "test_helper"
require "flare/sampler"

class SamplerTest < Minitest::Test
  def setup
    @sampler = Flare::Sampler.new
  end

  # ----- Decisions ---------------------------------------------------------

  def test_returns_record_only_when_no_rules
    result = sample(attrs: { "code.namespace" => "X" }, trace_id: low_trace_id)
    refute result.sampled?
  end

  def test_returns_record_and_sample_when_a_rule_matches_and_ratio_passes
    @sampler.update_rules([rule(id: 1, match: { "code.namespace" => "UsersJob" }, rate: 1.0)])
    result = sample(attrs: { "code.namespace" => "UsersJob" }, trace_id: low_trace_id)

    assert result.sampled?
    assert_equal 1, result.attributes[Flare::Sampler::RULE_ID_ATTRIBUTE]
  end

  def test_returns_record_only_when_ratio_exceeds_rule_rate
    @sampler.update_rules([rule(id: 1, match: { "code.namespace" => "UsersJob" }, rate: 0.1)])
    result = sample(attrs: { "code.namespace" => "UsersJob" }, trace_id: high_trace_id)

    refute result.sampled?
  end

  def test_skips_rules_whose_attributes_are_not_present
    @sampler.update_rules([rule(id: 1, match: { "code.namespace" => "OtherJob" }, rate: 1.0)])
    result = sample(attrs: { "code.namespace" => "UsersJob" }, trace_id: low_trace_id)

    refute result.sampled?
  end

  def test_requires_every_match_attribute_to_be_present
    @sampler.update_rules([
      rule(id: 1, match: { "code.namespace" => "UsersController", "code.function" => "show" }, rate: 1.0)
    ])

    only_one = sample(attrs: { "code.namespace" => "UsersController" }, trace_id: low_trace_id)
    refute only_one.sampled?

    both = sample(
      attrs:    { "code.namespace" => "UsersController", "code.function" => "show" },
      trace_id: low_trace_id
    )
    assert both.sampled?
  end

  def test_preserves_parent_tracestate_on_record_and_sample
    @sampler.update_rules([rule(id: 1, match: { "x" => "y" }, rate: 1.0)])
    tracestate = OpenTelemetry::Trace::Tracestate.from_string("vendor=value")
    parent_ctx = mock_parent_context(tracestate)

    result = sample(attrs: { "x" => "y" }, trace_id: low_trace_id, parent: parent_ctx)
    assert_same tracestate, result.tracestate
  end

  def test_preserves_parent_tracestate_on_record_only
    tracestate = OpenTelemetry::Trace::Tracestate.from_string("vendor=value")
    parent_ctx = mock_parent_context(tracestate)

    result = sample(attrs: {}, trace_id: low_trace_id, parent: parent_ctx)
    assert_same tracestate, result.tracestate
  end

  # ----- Validation --------------------------------------------------------

  def test_drops_malformed_rules_and_counts_them
    @sampler.update_rules([
      { "id" => 1, "match_attributes" => { "k" => "v" }, "rate" => 0.5 },     # ok
      { "id" => 2 },                                                          # missing match
      { "id" => 3, "match_attributes" => { "k" => "v" }, "rate" => "0.5" },   # rate not numeric
      { "id" => 4, "match_attributes" => { "k" => "v" }, "rate" => 1.5 },     # rate > 1
      { "id" => 5, "match_attributes" => {}, "rate" => 0.5 },                 # empty attrs
      { "id" => 6, "match_attributes" => { "k" => "" }, "rate" => 0.5 },      # empty value
      nil,                                                                     # not a hash
      "not a hash"
    ])

    assert_equal [1], @sampler.rules.map(&:id)
    assert_equal 7, @sampler.dropped_rule_count.value
  end

  def test_update_rules_replaces_the_set_atomically
    @sampler.update_rules([rule(id: 1, match: { "k" => "a" }, rate: 1.0)])
    @sampler.update_rules([rule(id: 2, match: { "k" => "b" }, rate: 1.0)])

    assert_equal [2], @sampler.rules.map(&:id)
  end

  # ----- trace_id_ratio ----------------------------------------------------

  # ----- Capture mode ------------------------------------------------------

  def test_rules_keep_the_capture_mode_the_server_sent
    @sampler.update_rules([
      rule(id: 1, match: { "code.namespace" => "A" }, rate: 1.0).merge("capture" => "slo_failures"),
      rule(id: 2, match: { "code.namespace" => "B" }, rate: 1.0).merge("capture" => "all_requests"),
      rule(id: 3, match: { "code.namespace" => "C" }, rate: 1.0),
      rule(id: 4, match: { "code.namespace" => "D" }, rate: 1.0).merge("capture" => "errors")
    ])

    assert_equal "slo_failures", @sampler.judged_rule(1).capture
    assert_nil @sampler.judged_rule(2)
    assert_nil @sampler.judged_rule(3), "a server that predates capture means all_requests"
    assert_equal "errors", @sampler.judged_rule(4).capture
  end

  def test_unknown_capture_mode_keeps_the_rule_as_all_requests
    @sampler.update_rules([rule(id: 1, match: { "code.namespace" => "A" }, rate: 1.0).merge("capture" => "someday")])

    assert_equal 1, @sampler.rules.length
    assert_equal 0, @sampler.dropped_rule_count.value
    assert_equal "all_requests", @sampler.rules.first.capture
    assert_nil @sampler.judged_rule(1)
  end

  def test_judged_rule_is_nil_for_a_rule_that_is_gone
    @sampler.update_rules([rule(id: 1, match: { "code.namespace" => "A" }, rate: 1.0).merge("capture" => "slo_failures")])

    assert_nil @sampler.judged_rule(99)
    assert_nil @sampler.judged_rule(nil)
  end

  def test_baseline_is_true_only_when_the_server_says_true
    @sampler.update_rules([
      rule(id: 1, match: { "code.namespace" => "A" }, rate: 1.0).merge("capture" => "slo_failures", "baseline" => true),
      rule(id: 2, match: { "code.namespace" => "B" }, rate: 1.0).merge("capture" => "slo_failures", "baseline" => "yes"),
      rule(id: 3, match: { "code.namespace" => "C" }, rate: 1.0).merge("capture" => "slo_failures")
    ])

    assert_equal [true, false, false], @sampler.rules.map(&:baseline)
  end

  # ----- Filters -----------------------------------------------------------

  def test_filters_are_compiled_once_and_make_an_all_requests_rule_judged
    @sampler.update_rules([
      rule(id: 1, match: { "code.namespace" => "A" }, rate: 1.0).merge(
        "capture" => "all_requests",
        "filters" => [
          { "field" => "url.path", "op" => "prefix", "value" => "/passages/", "negate" => false },
          { "field" => "http.status_code", "op" => "between", "value" => [500, 599], "negate" => true }
        ]
      )
    ])

    rule = @sampler.judged_rule(1)
    assert rule, "filters mean the request must finish before we know whether to keep it"
    assert_equal 2, rule.filters.length
    assert(rule.filters.all? { |filter| filter.is_a?(Flare::TraceFilter) })
    assert rule.filters.frozen?
  end

  def test_rule_with_an_unknown_filter_op_is_dropped
    @sampler.update_rules([
      rule(id: 1, match: { "code.namespace" => "A" }, rate: 1.0).merge(
        "filters" => [{ "field" => "url.path", "op" => "regex", "value" => "/passages/.*" }]
      ),
      rule(id: 2, match: { "code.namespace" => "B" }, rate: 1.0).merge(
        "filters" => [{ "field" => "user.id", "op" => "equals", "value" => "1" }]
      ),
      rule(id: 3, match: { "code.namespace" => "C" }, rate: 1.0).merge("filters" => "url.path=/a"),
      rule(id: 4, match: { "code.namespace" => "D" }, rate: 1.0).merge("filters" => [])
    ])

    assert_equal [4], @sampler.rules.map(&:id)
    assert_equal 3, @sampler.dropped_rule_count.value
    assert_nil @sampler.judged_rule(4), "no filters and all_requests is not judged"
  end

  def test_trace_id_ratio_is_deterministic_per_id
    a = @sampler.trace_id_ratio("\x00" * 16)
    b = @sampler.trace_id_ratio("\x00" * 16)
    assert_equal a, b
  end

  def test_trace_id_ratio_lands_in_zero_to_one
    100.times do
      bytes = SecureRandom.bytes(16)
      r = @sampler.trace_id_ratio(bytes)
      assert r >= 0.0 && r < 1.0, "got #{r}"
    end
  end

  # ----- AlwaysRecordOnly --------------------------------------------------

  def test_always_record_only_returns_record_only
    result = Flare::ALWAYS_RECORD_ONLY.should_sample?(
      trace_id: low_trace_id, parent_context: nil, links: nil, name: nil, kind: nil, attributes: nil
    )
    refute result.sampled?
  end

  def test_always_record_only_preserves_parent_tracestate
    tracestate = OpenTelemetry::Trace::Tracestate.from_string("vendor=v")
    result = Flare::ALWAYS_RECORD_ONLY.should_sample?(parent_context: mock_parent_context(tracestate))
    assert_same tracestate, result.tracestate
  end

  private

  def rule(id:, match:, rate:)
    { "id" => id, "match_attributes" => match, "rate" => rate }
  end

  def sample(attrs:, trace_id:, parent: nil)
    @sampler.should_sample?(
      trace_id:       trace_id,
      parent_context: parent,
      links:          nil,
      name:           "test",
      kind:           :server,
      attributes:     attrs
    )
  end

  # Trace ids the deterministic ratio resolves to ~0.0 / ~1.0 respectively.
  def low_trace_id  = "\x00" * 16
  def high_trace_id = "\xff" * 16

  def mock_parent_context(tracestate)
    span_context = OpenTelemetry::Trace::SpanContext.new(
      trace_id: "\x01".b * 16,
      span_id: "\x02".b * 8,
      tracestate: tracestate
    )
    OpenTelemetry::Trace.context_with_span(OpenTelemetry::Trace.non_recording_span(span_context))
  end
end
