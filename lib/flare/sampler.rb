# frozen_string_literal: true

require "concurrent/atomic/atomic_reference"
require "opentelemetry/sdk"

module Flare
  # Path 1 trace sampler. At span start, iterates active rules; returns
  # RECORD_AND_SAMPLE when one matches and the deterministic trace_id_ratio
  # falls under the rule's rate. Otherwise RECORD_ONLY -- the span still
  # records so MetricSpanProcessor sees it; the trace export decision for
  # web spans is deferred to Path 2 via Flare::Marker.
  #
  # Used as the `root` sampler inside an OTel ParentBased sampler so root
  # spans go through this logic but child spans inherit upstream decisions.
  # The `local_parent_not_sampled` slot of the ParentBased should point at
  # Flare::ALWAYS_RECORD_ONLY -- the default ALWAYS_OFF would drop children
  # of an unsampled local parent, making them NoOp spans the processors
  # never see.
  #
  # Rules are pushed in via update_rules from Flare::RuleManager; the swap
  # is atomic, and malformed rule entries are dropped with a counter so a
  # bad server payload can't crash the tracing path.
  class Sampler
    Decision = OpenTelemetry::SDK::Trace::Samplers::Decision
    Result   = OpenTelemetry::SDK::Trace::Samplers::Result

    RULE_ID_ATTRIBUTE = "flare.rule_id"
    CAPTURE_REASON_ATTRIBUTE = "flare.capture_reason"

    # What a rule keeps. all_requests uploads every request it samples.
    # slo_failures uploads only requests that fail their operation's latency
    # SLO (slow or errored); FilteringSpanProcessor drops the rest when the
    # request ends. A missing or unknown value means all_requests, which is
    # what servers that predate the field mean.
    CAPTURE_ALL_REQUESTS = "all_requests"
    CAPTURE_SLO_FAILURES = "slo_failures"

    Rule = Struct.new(:id, :match_attributes, :rate, :capture, keyword_init: true)

    attr_reader :dropped_rule_count

    def initialize
      @rules_ref = Concurrent::AtomicReference.new([].freeze)
      @dropped_rule_count = Concurrent::AtomicFixnum.new(0)
    end

    # new_rules: an array of rule hashes from GET /api/rules, e.g.
    #   [{ "id" => 1, "match_attributes" => {...}, "rate" => 0.5, "capture" => "slo_failures" }, ...]
    # Entries that don't validate are skipped (counted in dropped_rule_count).
    def update_rules(new_rules)
      validated = (new_rules || []).filter_map { |r| validate(r) }
      @dropped_rule_count.increment((new_rules || []).length - validated.length)
      @rules_ref.set(validated.freeze)
    end

    def rules
      @rules_ref.get
    end

    # True when the rule with this id keeps only SLO failures. False for an
    # unknown id (the rule expired mid-request), which keeps today's
    # all_requests behavior.
    def capture_slo_failures?(rule_id)
      return false if rule_id.nil?

      rules.any? { |rule| rule.id == rule_id && rule.capture == CAPTURE_SLO_FAILURES }
    end

    def should_sample?(trace_id:, parent_context:, links:, name:, kind:, attributes:)
      tracestate = tracestate_from(parent_context)

      rules.each do |rule|
        next unless matches?(rule, attributes)
        next unless trace_id_ratio(trace_id) < rule.rate

        merged = (attributes || {}).merge(RULE_ID_ATTRIBUTE => rule.id)
        return Result.new(decision: Decision::RECORD_AND_SAMPLE, attributes: merged, tracestate: tracestate)
      end

      Result.new(decision: Decision::RECORD_ONLY, tracestate: tracestate)
    end

    def description
      "Flare::Sampler"
    end

    # Cross-language formula: last 8 bytes of the 16-byte raw trace_id as
    # uint64-big-endian, divided by 2^64. Same in every Flare SDK so the
    # server can reproduce the decision if it ever needs to.
    def trace_id_ratio(trace_id)
      bytes = trace_id.is_a?(String) ? trace_id.bytes : Array(trace_id)
      tail = bytes.last(8)
      n = 0
      tail.each { |b| n = (n << 8) | b }
      n.to_f / (1 << 64)
    end

    private

    def tracestate_from(parent_context)
      OpenTelemetry::Trace.current_span(parent_context).context.tracestate ||
        OpenTelemetry::Trace::Tracestate::DEFAULT
    end

    def matches?(rule, attributes)
      return false if attributes.nil?
      rule.match_attributes.all? { |k, v| attributes[k] == v }
    end

    def validate(raw)
      return nil unless raw.is_a?(Hash)

      id    = raw["id"] || raw[:id]
      match = raw["match_attributes"] || raw[:match_attributes]
      rate  = raw["rate"] || raw[:rate]
      capture = raw["capture"] || raw[:capture]
      capture = CAPTURE_ALL_REQUESTS unless capture == CAPTURE_SLO_FAILURES

      return nil if id.nil?
      return nil unless match.is_a?(Hash) && match.any?
      return nil unless match.all? { |k, v| k.is_a?(String) && v.is_a?(String) && !v.empty? }
      return nil unless rate.is_a?(Numeric) && rate > 0.0 && rate <= 1.0

      Rule.new(id: id, match_attributes: match, rate: rate.to_f, capture: capture)
    rescue StandardError
      nil
    end
  end

  # Tiny sampler whose should_sample? returns RECORD_ONLY for every span.
  # Slot this into the ParentBased local_parent_not_sampled position so
  # children of an unsampled local parent stay recording (the default
  # ALWAYS_OFF turns them into NoOp spans no processor ever sees).
  class AlwaysRecordOnly
    Decision = OpenTelemetry::SDK::Trace::Samplers::Decision
    Result   = OpenTelemetry::SDK::Trace::Samplers::Result

    def should_sample?(parent_context: nil, **)
      tracestate = OpenTelemetry::Trace.current_span(parent_context).context.tracestate ||
        OpenTelemetry::Trace::Tracestate::DEFAULT
      Result.new(decision: Decision::RECORD_ONLY, tracestate: tracestate)
    end

    def description
      "Flare::AlwaysRecordOnly"
    end
  end

  ALWAYS_RECORD_ONLY = AlwaysRecordOnly.new
end
