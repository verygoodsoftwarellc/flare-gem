# frozen_string_literal: true

require "active_support"
require "active_support/parameter_filter"
require "set"
require "uri"

require_relative "sql_mask"
require_relative "utf8"

module Flare
  # Applies the app's filter_parameters and masks SQL values in span names and
  # attributes before a trace leaves the process. Attributes that name the code
  # or describe the request's shape are kept as they are, because the trace view
  # and trace rules read them. Everything else is treated as possibly holding a
  # value the app wouldn't want sent.
  class ExportFilter
    FILTERED = "[FILTERED]"
    MAX_TEXT_BYTES = SqlMask::MAX_BYTES

    # Applied even if the app's list is empty or was trimmed. Rails' generated
    # list, plus the names credentials go by in URLs and headers.
    DEFAULT_FILTERS = [
      :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
      /api.?key/i, /authoriz/i, /oauth/i, /\Aauth\z/i, /cookie/i, /session/i, /credential/i, /signature/i,
      /jwt/i, /bearer/i, /pwd/i, /\Apass\z/i, /\Akey\z/i, /\Asig\z/i, /\Acode\z/i
    ].freeze

    KEPT = %w[
      name identifier layout count cache_hits record_count class_name
      mailer action message_id hit exist store
      http.method http.request.method http.status_code http.response.status_code
      http.scheme url.scheme http.route http.user_agent user_agent.original
      db.system db.system.name db.name db.namespace
      db.sql.table db.collection.name db.redis.database_index
      exception.type server.port net.peer.port
    ].to_set.freeze
    KEPT_PREFIX = /\A(?:code|messaging|flare|otel)\./

    # What these hold can't be sorted into safe and unsafe parts: message bodies
    # and recipients, job arguments, request and exception contents.
    OPAQUE = %w[
      to from cc bcc reply_to subject mail
      args arguments params parameters headers cookies body payload request response env session
      exception exception_object exception.message exception.stacktrace
    ].to_set.freeze
    OPAQUE_PREFIX = /\Aemail\./

    OPERATIONS = %w[db.operation db.operation.name].to_set.freeze
    STATEMENTS = %w[db.statement db.query.text db.query db.sql sql statement query].to_set.freeze
    # A leading comment or parenthesis counts, since a statement can start with one.
    SQL_TEXT = %r{\A[\s(]*(?:/\*|--|(?:select|insert|update|delete|replace|merge|with|set|create|alter|drop|truncate|grant|revoke|explain|describe|show|call|exec|execute|values|copy|pragma|vacuum|lock|begin|prepare)\b)}i
    STRUCTURED_TEXT = /\A\s*[{\[]/

    URLS = %w[http.url url.full url.path http.target http.referer url.original].to_set.freeze
    HOSTS = %w[http.host server.address net.peer.name].to_set.freeze
    CACHE_NAMESPACE = /\A[A-Za-z][A-Za-z_-]{0,40}(?=[\/:])/

    URL_START = %r{\A((?:[a-z][a-z0-9+.-]*:)?//)([^/?#]*)(.*)\z}im
    NUMERIC_PORT = /\A(?:\[[^\]]*\]|[^:]*)(?::\d*)?\z/
    SCHEMELESS_USERINFO = %r{\A[^/?#]+@}
    PATH_USERINFO = %r{(?<=/|\A)[^/@]+@[^/]*}

    # One scan over free text, leftmost first, so what a URL contains is never read
    # as a key and value. key holds a pair's name; separator ends where its value
    # starts.
    TEXT_TOKEN = %r{
      (?<url>(?<!\w)(?:(?<![.+\-])[a-z][a-z0-9+.-]*+:)?//[^\s'"<>]++)
      |(?<auth>(?<!\w)(?:bearer\s+\S++|basic\s+[A-Za-z0-9+/=]{8,}+))
      |(?:
        (?<quote>["'])(?<quoted_key>[\w.\-\[\]%]++)\k<quote>
        |(?<![\w.\-\[\]%])(?<key>[\w.\-\[\]%]++)
      )\s*+(?:=>|=|:)\s*+
    }xi
    # A value longer than this is masked rather than judged on part of it.
    VALUE_WINDOW = 256
    VALUE = /\A[^\s&;,]*+/
    NESTED_VALUE = %r{=|%3d|//|%2f%2f|@|%40}i

    class << self
      # Built on use, and rebuilt if the list changes, because initializers and
      # engines can add to filter_parameters at any point during boot.
      def current
        filters = app_filters
        cached = @current
        return cached.last if cached && cached.first == filters

        filter = new(filters)
        @current = [filters.dup.freeze, filter]
        filter
      end

      private

      def app_filters
        return [] unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

        Array(Rails.application.config.filter_parameters)
      rescue StandardError
        []
      end
    end

    def initialize(filters = [])
      @parameter_filter = ActiveSupport::ParameterFilter.new(DEFAULT_FILTERS + filters)
    end

    def attributes(attrs)
      return {} if attrs.nil?

      system = attrs["db.system"] || attrs["db.system.name"]
      attrs.each_with_object({}) { |(name, value), out| out[name] = attribute(UTF8.scrub(name.to_s), value, system) }
    end

    def name(value)
      return value unless value.is_a?(String)

      free_text(clean(value))
    rescue StandardError
      FILTERED
    end

    private

    def attribute(name, value, system)
      return value if KEPT.include?(name) || KEPT_PREFIX.match?(name)
      return FILTERED if OPAQUE.include?(name) || OPAQUE_PREFIX.match?(name)

      case value
      when String then text_attribute(name, value, system)
      when Array then value.map { |item| attribute(name, item, system) }
      else param_kept?(name, value) ? value : FILTERED
      end
    rescue StandardError
      # A value that can't be processed doesn't go out.
      FILTERED
    end

    def text_attribute(name, value, system)
      return statement(value, system) if STATEMENTS.include?(name)
      return SqlMask.operation_word(value) || SqlMask::PLACEHOLDER if OPERATIONS.include?(name)

      text = clean(value)
      if URLS.include?(name) then url(text)
      elsif HOSTS.include?(name) then text.sub(/\A.*@/m, "")
      elsif name == "url.query" then query_string(text)
      elsif name == "key" then cache_key(text)
      elsif param_kept?(name, text) then free_text(text)
      else FILTERED
      end
    end

    def clean(value)
      UTF8.scrub(value.bytesize > MAX_TEXT_BYTES ? value.byteslice(0, MAX_TEXT_BYTES) : value)
    end

    def statement(text, system)
      unless SqlMask.sql_system?(system)
        command = SqlMask.command_word(clean(text))
        return command ? "#{command} #{SqlMask::PLACEHOLDER}" : SqlMask::PLACEHOLDER
      end

      masked = SqlMask.mask(text, system)
      masked.empty? ? SqlMask::PLACEHOLDER : masked
    end

    def url(text)
      match = URL_START.match(text)
      return without_fragment_and_query(text.sub(SCHEMELESS_USERINFO, "")) unless match

      scheme, authority, rest = match.captures
      if authority.include?("@")
        authority = authority.sub(/\A.*@/m, "")
      elsif !NUMERIC_PORT.match?(authority)
        return "#{scheme}#{FILTERED}"
      end

      "#{scheme}#{authority}#{without_fragment_and_query(rest)}"
    end

    def without_fragment_and_query(text)
      base, query = text.split("#", 2).first.to_s.split("?", 2)
      base = base.to_s.gsub(PATH_USERINFO, FILTERED)
      query ? "#{base}?#{query_string(query)}" : base
    end

    def query_string(text)
      text.gsub(/[^&;]+/) { |part| pair(part) }
    end

    def pair(part)
      key, value = part.split("=", 2)
      return FILTERED if value.nil?

      pair_kept?(key, value) ? part : "#{key}=#{FILTERED}"
    end

    def pair_kept?(key, value)
      !NESTED_VALUE.match?(value) && param_kept?(URI.decode_www_form_component(key), value)
    end

    # user[password]=x is checked as nested params, so filters written as
    # "user.password" apply to it too.
    def param_kept?(key, value)
      unless key.include?("[")
        result = @parameter_filter.filter_param(key, value)
        return result.equal?(value) || result == value
      end

      path = key.split(/[\[\]]+/).reject(&:empty?)
      nested = path.reverse.inject(value) { |inner, part| { part => inner } }
      @parameter_filter.filter(nested) == nested
    end

    # Keeps the leading word of a key like views/posts/1-abc or rack:attack:1.2.3.4,
    # so a trace still shows what kind of entry it was.
    def cache_key(text)
      namespace = text[CACHE_NAMESPACE]
      namespace ? "#{namespace}#{text[namespace.length]}#{SqlMask::PLACEHOLDER}" : SqlMask::PLACEHOLDER
    end

    # Text with no known meaning: custom notification payloads, span names. Masks
    # more than it needs to rather than guess where a value ends.
    def free_text(text)
      return FILTERED if STRUCTURED_TEXT.match?(text)
      # What's left of SQL is still read for pairs, since a word like DROP can also
      # start ordinary text.
      text = SqlMask.mask(text) if SQL_TEXT.match?(text)

      out = +""
      position = 0
      while (match = TEXT_TOKEN.match(text, position))
        out << text[position...match.begin(0)]
        position = match.end(0)

        if match[:url] then out << text_url(match[:url])
        elsif match[:auth] then out << match[:auth].split(/\s+/).first << " " << FILTERED
        else
          out << match[0]
          value = text[position, VALUE_WINDOW + 1][VALUE]
          next if value.length <= VALUE_WINDOW && pair_kept?(match[:key] || match[:quoted_key], value)

          out << FILTERED
          position = sensitive_value_end(text, position)
        end
      end
      out << text[position..]
    end

    def text_url(found)
      scheme = found[/\A[^:\/]+(?=:)/]
      scheme && !param_kept?(scheme, found) ? FILTERED : url(found)
    end

    # A quoted value may hold escapes and line breaks, so it masks everything after
    # it. Otherwise the line ends it, which covers multi-word values like cookie
    # lists.
    def sensitive_value_end(text, position)
      return text.length if text[position] == '"' || text[position] == "'"

      text.index("\n", position) || text.length
    end
  end
end
