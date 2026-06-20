# frozen_string_literal: true

require "concurrent/atomic/atomic_reference"

module Flare
  # Holds the latency SLO thresholds delivered by the server in the `slo_rules`
  # array of GET /api/rules. MetricSpanProcessor asks threshold_for at every
  # web/job span end to decide whether the operation was "too slow" -- the
  # latency SLI counterpart to error_count.
  #
  # The wire shape is a flat array of rules, each { namespace, service?, target?,
  # threshold_ms }:
  #   - a namespace-only rule sets that namespace's default (e.g. web => 1000);
  #   - a rule that also carries service + target is a per-operation override.
  # Internally these split into a defaults hash (keyed by namespace) and an
  # overrides hash (keyed by [namespace, service, target]).
  #
  # Precedence in threshold_for: exact override -> namespace default -> nil.
  # nil means "untracked" -- the processor records no slow_count for it.
  #
  # The whole config is swapped atomically (like Sampler#update_rules) so a
  # mid-poll read always sees a consistent defaults+overrides pair. Malformed
  # rules from a bad server payload are dropped rather than raising.
  class SloManager
    Config = Struct.new(:defaults, :overrides, keyword_init: true)

    EMPTY = Config.new(defaults: {}.freeze, overrides: {}.freeze).freeze

    def initialize
      @config_ref = Concurrent::AtomicReference.new(EMPTY)
    end

    # slo_rules: flat array of { "namespace", "service"?, "target"?,
    # "threshold_ms" } hashes (string or symbol keys accepted). A namespace-only
    # rule is that namespace's default; namespace + service + target is an
    # override. Rules missing namespace/threshold, or with only one of
    # service/target, are skipped. An absent/empty array clears the config.
    def update(slo_rules)
      defaults = {}
      overrides = {}

      Array(slo_rules).each do |rule|
        next unless rule.is_a?(Hash)

        namespace = stringify(rule["namespace"] || rule[:namespace])
        service   = stringify(rule["service"]   || rule[:service])
        target    = stringify(rule["target"]    || rule[:target])
        threshold = coerce_threshold(rule["threshold_ms"] || rule[:threshold_ms])

        next if namespace.nil? || threshold.nil?

        if service && target
          overrides[[namespace, service, target]] = threshold
        elsif service.nil? && target.nil?
          defaults[namespace] = threshold
        end
      end

      @config_ref.set(Config.new(defaults: defaults.freeze, overrides: overrides.freeze).freeze)
    end

    # Returns the threshold in integer milliseconds for this operation, or nil
    # when the operation is untracked (no override and no namespace default).
    def threshold_for(namespace:, service:, target:)
      config = @config_ref.get
      config.overrides[[namespace, service, target]] || config.defaults[namespace]
    end

    # Latency SLI predicate: true when the operation exceeded its SLO threshold
    # and did not error. Kept disjoint from errors so error_count + slow_count
    # never double-counts. Untracked operations (no threshold) are never slow.
    def slow?(namespace:, service:, target:, duration_ms:, error:)
      return false if error

      threshold = threshold_for(namespace: namespace, service: service, target: target)
      !threshold.nil? && duration_ms > threshold
    end

    def defaults
      @config_ref.get.defaults
    end

    def overrides
      @config_ref.get.overrides
    end

    private

    def stringify(value)
      return nil if value.nil?

      str = value.to_s
      str.empty? ? nil : str
    end

    def coerce_threshold(value)
      return nil if value.nil?
      return nil unless value.is_a?(Numeric) || value.to_s.match?(/\A\d+\z/)

      ms = value.to_i
      ms.positive? ? ms : nil
    end
  end
end
