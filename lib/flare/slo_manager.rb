# frozen_string_literal: true

require "concurrent/atomic/atomic_reference"

module Flare
  # Holds the latency SLO thresholds delivered by the server in the `slo`
  # section of GET /api/rules. MetricSpanProcessor asks threshold_for at every
  # web/job span end to decide whether the operation was "too slow" -- the
  # latency SLI counterpart to error_count.
  #
  # Two layers, mirroring the server config:
  #   - defaults: per-namespace fallback, e.g. { "web" => 1000, "job" => 60000 }.
  #     A namespace may be absent (its default was cleared = stop tracking it).
  #   - operations: per-operation overrides keyed by [namespace, service, target].
  #
  # Precedence in threshold_for: per-op override -> namespace default -> nil.
  # nil means "untracked" -- the processor records no slow_count for it.
  #
  # The whole config is swapped atomically (like Sampler#update_rules) so a
  # mid-poll read always sees a consistent defaults+operations pair. Malformed
  # entries from a bad server payload are dropped rather than raising.
  class SloManager
    Config = Struct.new(:defaults, :operations, keyword_init: true)

    EMPTY = Config.new(defaults: {}.freeze, operations: {}.freeze).freeze

    def initialize
      @config_ref = Concurrent::AtomicReference.new(EMPTY)
    end

    # defaults:   hash like { "web" => 1000, "job" => 60000 } (string or symbol
    #             keys accepted; nil/blank values dropped).
    # operations: array of { "namespace", "service", "target", "threshold_ms" }
    #             hashes; entries missing a field or threshold are skipped.
    def update(defaults: nil, operations: nil)
      @config_ref.set(Config.new(
        defaults: normalize_defaults(defaults),
        operations: normalize_operations(operations)
      ).freeze)
    end

    # Returns the threshold in integer milliseconds for this operation, or nil
    # when the operation is untracked (no override and no namespace default).
    def threshold_for(namespace:, service:, target:)
      config = @config_ref.get
      override = config.operations[[namespace, service, target]]
      return override if override

      config.defaults[namespace]
    end

    def defaults
      @config_ref.get.defaults
    end

    def operations
      @config_ref.get.operations
    end

    private

    def normalize_defaults(defaults)
      return {}.freeze unless defaults.is_a?(Hash)

      result = {}
      defaults.each do |namespace, threshold|
        ms = coerce_threshold(threshold)
        result[namespace.to_s] = ms if ms
      end
      result.freeze
    end

    def normalize_operations(operations)
      return {}.freeze unless operations.is_a?(Array)

      result = {}
      operations.each do |op|
        next unless op.is_a?(Hash)

        namespace = op["namespace"] || op[:namespace]
        service   = op["service"]   || op[:service]
        target    = op["target"]    || op[:target]
        threshold = coerce_threshold(op["threshold_ms"] || op[:threshold_ms])

        next if namespace.nil? || service.nil? || target.nil? || threshold.nil?

        result[[namespace.to_s, service.to_s, target.to_s]] = threshold
      end
      result.freeze
    end

    def coerce_threshold(value)
      return nil if value.nil?
      return nil unless value.is_a?(Numeric) || value.to_s.match?(/\A\d+\z/)

      ms = value.to_i
      ms.positive? ? ms : nil
    end
  end
end
