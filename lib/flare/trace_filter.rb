# frozen_string_literal: true

require "rack/utils"

module Flare
  # One request filter from a trace rule, compiled once when rules arrive
  # from /api/rules and checked against the span that completes a request.
  #
  #   { "field" => "url.path", "op" => "prefix", "value" => "/passages/", "negate" => false }
  #
  # A rule keeps a request only when every filter matches (negate flips one
  # filter's result). Request fields (method, path, query param, status) only
  # exist on a web request's server span, so they never match a job, negated
  # or not. Paths match by prefix, equality or glob, never regex, because
  # this runs inside the app on every judged request.
  class TraceFilter
    OPS = {
      "http.method" => %w[in],
      "url.path" => %w[prefix equals glob],
      "url.query_param" => %w[present equals],
      "http.status_code" => %w[between],
      "duration_ms" => %w[between]
    }.freeze

    # Returns a TraceFilter, or nil when the entry is malformed or names a
    # field or op this SDK doesn't know. The Sampler drops a rule with any
    # nil filter rather than guess what it meant.
    def self.build(raw)
      return nil unless raw.is_a?(Hash)

      field = read(raw, "field")
      op = read(raw, "op")
      return nil unless OPS.fetch(field, []).include?(op)

      negate = raw_key?(raw, "negate") ? read(raw, "negate") : false
      return nil unless [true, false].include?(negate)

      value = normalize_value(field, op, read(raw, "value"))
      return nil if value.nil? && op != "present"

      name = read(raw, "name")
      return nil if field == "url.query_param" && !text?(name)

      new(field: field, op: op, value: value, name: name, negate: negate)
    rescue StandardError
      nil
    end

    def self.normalize_value(field, op, value)
      case op
      when "in"
        return nil if !value.is_a?(Array) || value.empty?
        return nil unless value.all? { |v| text?(v) }

        value.map(&:upcase).freeze
      when "prefix", "equals", "glob"
        return value.freeze if field == "url.query_param" && value.is_a?(String)
        return nil unless text?(value)

        value.freeze
      when "between"
        return nil if !value.is_a?(Array) || value.length != 2

        lo, hi = value
        return nil if !bound?(lo) || !bound?(hi)
        return nil if lo && hi && lo > hi

        [lo, hi].freeze
      end
    end

    def self.text?(value)
      value.is_a?(String) && !value.empty?
    end

    def self.bound?(value)
      value.nil? || (value.is_a?(Numeric) && value.finite?)
    end

    def self.read(raw, key)
      raw.key?(key) ? raw[key] : raw[key.to_sym]
    end

    def self.raw_key?(raw, key)
      raw.key?(key) || raw.key?(key.to_sym)
    end

    private_class_method :normalize_value, :text?, :bound?, :read, :raw_key?

    attr_reader :field, :op, :value, :name

    def initialize(field:, op:, value:, name: nil, negate: false)
      @field = field
      @op = op
      @value = value
      @name = name
      @negate = negate
      freeze
    end

    def negate?
      @negate
    end

    def match?(span)
      return @negate ^ within?(duration_ms(span)) if @field == "duration_ms"
      return false unless server_span?(span)

      @negate ^ request_match?(span.attributes || {})
    end

    private

    def request_match?(attributes)
      case @field
      when "http.method"
        method = attributes["http.method"] || attributes["http.request.method"]
        !method.nil? && @value.include?(method.to_s.upcase)
      when "url.path"
        path_match?(request_path(attributes))
      when "url.query_param"
        query_param_match?(query_params(attributes))
      when "http.status_code"
        status = attributes["http.status_code"] || attributes["http.response.status_code"]
        !status.nil? && within?(status.to_i)
      else
        false
      end
    end

    def path_match?(path)
      return false if path.nil?

      case @op
      when "prefix" then path.start_with?(@value)
      when "equals" then path == @value
      when "glob" then File.fnmatch(@value, path, File::FNM_PATHNAME)
      else false
      end
    end

    def query_param_match?(params)
      return params.key?(@name) if @op == "present"

      Array(params[@name]).include?(@value)
    end

    def request_path(attributes)
      path = attributes["url.path"]
      return path.to_s if path

      target = attributes["http.target"]
      target&.to_s&.split("?", 2)&.first
    end

    def query_params(attributes)
      query = attributes["url.query"]
      if query.nil?
        target = attributes["http.target"]
        query = target&.to_s&.split("?", 2)&.[](1)
      end
      return {} if query.nil? || query.empty?

      Rack::Utils.parse_query(query)
    rescue StandardError
      # A malformed query string (bad percent-encoding) has no params to match.
      {}
    end

    def within?(number)
      return false if number.nil?

      lo, hi = @value
      (lo.nil? || number >= lo) && (hi.nil? || number <= hi)
    end

    def duration_ms(span)
      start = span.start_timestamp if span.respond_to?(:start_timestamp)
      finish = span.end_timestamp if span.respond_to?(:end_timestamp)
      return nil if start.nil? || finish.nil?

      (finish - start) / 1_000_000.0
    end

    def server_span?(span)
      span.respond_to?(:kind) && span.kind == :server
    end
  end
end
