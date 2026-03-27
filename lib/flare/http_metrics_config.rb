# frozen_string_literal: true

module Flare
  class HttpMetricsConfig
    class HostConfig
      attr_reader :rules

      def initialize
        @rules = []
        @all = false
      end

      def initialize_copy(source)
        @rules = source.rules.dup
      end

      def all?
        @all
      end

      # Track all paths for this host (normalized via normalize_path)
      def all
        @all = true
      end

      # Track paths matching this regex (normalized via normalize_path)
      def allow(pattern)
        @rules << {pattern: pattern, replacement: nil}
      end

      # Track paths matching this regex with a custom replacement string
      def map(pattern, replacement)
        @rules << {pattern: pattern, replacement: replacement}
      end

      # Returns the resolved path for a given raw path, or "*" if no match.
      # If :all, returns nil to signal "use normalize_path".
      # If a rule matches with a replacement, returns the replacement.
      # If a rule matches without a replacement, returns nil to signal "use normalize_path".
      # If no rules match, returns "*".
      def resolve(path)
        return nil if @all

        @rules.each do |rule|
          if rule[:pattern].match?(path)
            return rule[:replacement] # nil means use normalize_path
          end
        end

        "*"
      end
    end

    def initialize
      @hosts = {}
    end

    def initialize_copy(source)
      @hosts = source.instance_variable_get(:@hosts).transform_values(&:dup)
    end

    def host(hostname, mode = nil, &block)
      config = @hosts[hostname] ||= HostConfig.new

      if mode == :all
        config.all
      elsif block
        yield config
      end
    end

    # Resolve a host+path to the target path for metrics.
    # Returns "*" for unknown hosts or unmatched paths.
    # Returns nil to signal "use normalize_path".
    # Returns a string for custom replacements.
    def resolve(hostname, path)
      host_config = @hosts[hostname]
      return "*" unless host_config

      host_config.resolve(path)
    end

    DEFAULT = new.tap do |config|
      config.host "flare.am" do |h|
        h.allow %r{/api/metrics}
      end

      config.host "www.flippercloud.io" do |h|
        h.map %r{/adapter/features/[^/]+/(boolean|actors|groups|percentage_of_actors|percentage_of_time|expression|clear)}, "/adapter/features/:name/:gate"
        h.map %r{/adapter/features/[^/]+}, "/adapter/features/:name"
        h.map %r{/adapter/actors/[^/]+}, "/adapter/actors/:id"
        h.allow %r{/adapter/features}
        h.allow %r{/adapter/import}
        h.allow %r{/adapter/telemetry/summary}
        h.allow %r{/adapter/telemetry}
        h.allow %r{/adapter/events}
        h.allow %r{/adapter/audits}
      end
    end.freeze
  end
end
