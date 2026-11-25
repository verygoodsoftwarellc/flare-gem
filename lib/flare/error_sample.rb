# frozen_string_literal: true

require "json"
require "zlib"
require "stringio"

require_relative "error_fingerprint"
require_relative "utf8"
require_relative "version"

module Flare
  # One stored copy of an error occurrence, uploaded to R2 the first time a
  # process sees a fingerprint. No values leave the process: the message has
  # numbers, emails and quoted strings masked, and params are names only.
  module ErrorSample
    MAX_FRAMES = 200
    MAX_BYTES = 256 * 1024
    MAX_MESSAGE_BYTES = 4_096
    MAX_PARAM_NAMES = 100
    MAX_NAME_BYTES = 200
    MASK = "?"

    # A quoted identifier right after "method", "variable" or "constant" names
    # code ("undefined method 'name' for nil"), not data, so it stays.
    CODE_NAME = /(?<=method |variable |constant )[`'][A-Za-z_][\w:]*[?!=]?'/
    # A quote right after a letter is an apostrophe ("Couldn't"), not a value.
    QUOTED = /(?<!\w)(?:"(?:[^"\\]|\\.)*+"|'(?:[^'\\]|\\.)*+'|`(?:[^`\\]|\\.)*+`)/
    EMAIL = /[\w.+%-]+@[\w-]+(?:\.[\w-]+)+/
    UUID = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/
    # Hex ids and digests: 8+ hex chars with both a digit and a letter.
    HEX = /\b(?:0x)?(?=\h*\d)(?=\h*[a-f])\h{8,}\b/i
    NUMBER = /-?\d+(?:\.\d+)?/
    VALUES = /(?<code>#{CODE_NAME})|#{QUOTED}|#{EMAIL}|#{UUID}|#{HEX}|#{NUMBER}/

    module_function

    # Same idea as SqlMask, for free text: values out, wording kept.
    def scrub_message(message)
      text = UTF8.scrub(message.to_s)
      text = "#{text.byteslice(0, MAX_MESSAGE_BYTES).scrub("")} ..." if text.bytesize > MAX_MESSAGE_BYTES

      text.gsub(VALUES) { |match| Regexp.last_match(:code) ? match : MASK }
    end

    # Up to MAX_FRAMES frames. Every app frame stays; when there are too many,
    # gem frames are cut from the middle, keeping those nearest the top (where
    # it raised) and the bottom (how it got there).
    def trim_frames(frames, max = MAX_FRAMES)
      return [frames, 0] if frames.size <= max

      app_indexes = frames.each_index.select { |i| frames[i].app }
      if app_indexes.size >= max
        keep = app_indexes.first(max - max / 2) + app_indexes.last(max / 2)
      else
        other = frames.each_index.reject { |i| frames[i].app }
        room = max - app_indexes.size
        keep = app_indexes + other.first(room - room / 2) + other.last(room / 2)
      end
      kept = keep.uniq.sort.map { |i| frames[i] }
      [kept, frames.size - kept.size]
    end

    # Flattens nested params into names only: {"user" => {"email" => "a"}}
    # -> ["user[email]"].
    def param_names(params, prefix = nil, depth = 0, names = [])
      return names unless params.respond_to?(:each_pair)

      params.each_pair do |key, value|
        break if names.size >= MAX_PARAM_NAMES

        name = prefix ? "#{prefix}[#{key}]" : key.to_s
        next if prefix.nil? && %w[controller action].include?(name)

        if value.respond_to?(:each_pair) && depth < 3
          param_names(value, name, depth + 1, names)
        else
          names << "#{name}#{"[]" if value.is_a?(Array)}".byteslice(0, MAX_NAME_BYTES)
        end
      end
      names
    end

    def build(exception:, class_name:, fingerprint:, frames:, handled:, operation:, occurred_at:,
              revision: nil, host: nil, hex_trace_id: nil, route: nil, params: [], source: nil)
      backtrace, omitted = trim_frames(frames)
      sample = {
        schema_version: 1,
        fingerprint: fingerprint,
        class: class_name,
        message: scrub_message(exception.message),
        handled: handled,
        operation: operation,
        route: route,
        params: params,
        occurred_at: occurred_at.utc.iso8601(3),
        revision: revision,
        host: host,
        hex_trace_id: hex_trace_id,
        source: source,
        language: "ruby",
        language_version: RUBY_VERSION,
        sdk_version: Flare::VERSION,
        frames: frames.select(&:app).map(&:normalized).uniq.first(ErrorFingerprint::FINGERPRINT_FRAMES * 4),
        backtrace: backtrace.map(&:to_h),
        omitted_frames: omitted
      }
      cause = exception.cause
      sample[:cause] = { class: cause.class.name, message: scrub_message(cause.message) } if cause
      fit(UTF8.scrub(sample))
    end

    # The JSON for a sample, or nil when it can't be brought under MAX_BYTES.
    # Shrinks the parts that can be big before giving up.
    def fit(sample)
      json = JSON.generate(sample)
      return json if json.bytesize <= MAX_BYTES

      sample = sample.merge(message: sample[:message].to_s.byteslice(0, 1_024).scrub("")).tap { |s| s.delete(:cause) }
      json = JSON.generate(sample)
      return json if json.bytesize <= MAX_BYTES

      [50, 10].each do |max|
        frames = sample[:backtrace].map { |h| ErrorFingerprint::Frame.new(**h) }
        kept, omitted = trim_frames(frames, max)
        sample = sample.merge(backtrace: kept.map(&:to_h), omitted_frames: sample[:omitted_frames] + omitted, params: [])
        json = JSON.generate(sample)
        return json if json.bytesize <= MAX_BYTES
      end
      nil
    end

    def gzip(json)
      io = StringIO.new
      io.set_encoding(Encoding::BINARY)
      gz = Zlib::GzipWriter.new(io)
      gz.write(json)
      gz.close
      io.string
    end
  end
end
