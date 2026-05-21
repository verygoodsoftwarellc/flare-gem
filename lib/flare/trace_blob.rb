# frozen_string_literal: true

require "time"

module Flare
  # Value object that turns a group of OTel span_data for a single trace
  # into the Flare-JSON wire format the server expects:
  #
  #   {
  #     "trace_id":       "<hex>",
  #     "trace_rule_id":  <int|nil>,
  #     "root_name":      "<string>",
  #     "started_at":     "<iso8601>",
  #     "duration_ms":    <int>,
  #     "spans": [
  #       { "id", "parent_id", "name", "started_at",
  #         "duration_ms", "attributes" }
  #     ]
  #   }
  #
  # The trace_rule_id is read from any span carrying the
  # `flare.rule_id` attribute (Path 1 sets it on the sampled root, Path 2
  # sets it on the rack owner span via WebMarkerSubscriber).
  class TraceBlob
    ZERO_SPAN_ID = ("\x00".b * 8).freeze
    ROOT_NAME_LIMIT = 255

    def self.build(trace_id:, spans:)
      return nil if spans.nil? || spans.empty?
      new(trace_id: trace_id, spans: spans)
    end

    def initialize(trace_id:, spans:)
      @trace_id = trace_id
      @spans    = spans
    end

    def to_h
      root = find_root
      {
        "trace_id"      => hexify(@trace_id),
        "trace_rule_id" => rule_id_from_spans,
        "root_name"     => root_name(root),
        "started_at"    => iso(root&.start_timestamp),
        "duration_ms"   => duration_ms(root),
        "spans"         => @spans.map { |s| span_to_h(s) }
      }
    end

    private

    def find_root
      @spans.find { |s| root?(s) } || @spans.first
    end

    def root?(span)
      pid = span.parent_span_id
      pid.nil? || pid.empty? || pid == ZERO_SPAN_ID
    end

    def rule_id_from_spans
      @spans.each do |s|
        attrs = s.attributes
        next unless attrs
        value = attrs[Sampler::RULE_ID_ATTRIBUTE] || attrs[Sampler::RULE_ID_ATTRIBUTE.to_sym]
        return value if value
      end
      nil
    end

    def root_name(root)
      root&.name&.to_s&.slice(0, ROOT_NAME_LIMIT)
    end

    def span_to_h(span)
      {
        "id"          => hexify(span.span_id),
        "parent_id"   => root?(span) ? nil : hexify(span.parent_span_id),
        "name"        => span.name,
        "started_at"  => iso(span.start_timestamp),
        "duration_ms" => duration_ms(span),
        "attributes"  => span.attributes || {}
      }
    end

    def hexify(bytes)
      return nil if bytes.nil?
      bytes.unpack1("H*")
    end

    def iso(nanos)
      return nil if nanos.nil?
      Time.at(nanos / 1_000_000_000.0).utc.iso8601(6)
    end

    def duration_ms(span)
      return nil unless span && span.start_timestamp && span.end_timestamp
      ((span.end_timestamp - span.start_timestamp) / 1_000_000).to_i
    end
  end
end
