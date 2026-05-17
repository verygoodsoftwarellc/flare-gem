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
    Object.new.tap { |o| o.define_singleton_method(:trace_state) { tracestate } }
  end
end
