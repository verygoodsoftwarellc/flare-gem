# frozen_string_literal: true

require "json"
require "zlib"
require "stringio"

require_relative "error_fingerprint"
require_relative "utf8"
require_relative "version"

module Flare
  # One stored copy of an error occurrence, uploaded to R2 the first time a
  # process sees a fingerprint. No values leave the process: the message keeps
  # only plain words, and params are names only.
  module ErrorSample
    MAX_FRAMES = 200
    MAX_BYTES = 256 * 1024
    MAX_MESSAGE_BYTES = 4_096
    MAX_PARAM_NAMES = 100
    MAX_NAME_BYTES = 200
    MASK = "?"

    # Messages keep plain words and mask every other token, so a value can't
    # slip through a pattern nobody thought of: "Couldn't find User with
    # 'id'=123" -> "Couldn't find User with ?=?". A plain word is letters
    # (with _ and inner apostrophes or hyphens), plus sentence punctuation
    # around it.
    PLAIN_WORD = /\A[\p{L}_]+(?:['’-][\p{L}_]+)*\z/
    LEADING = /\A[(\[{]*/
    TRAILING = /[.,;:!?)\]}]*\z/
    # Plain words can still be data when they're quoted or assigned, so those
    # are masked whole first. A quote right after a letter is an apostrophe
    # ("Couldn't"). One that never closes (or was cut off) masks to the end; a
    # lone backslash at the end counts as part of it.
    QUOTED = /(?<!\w)(?:"(?:[^"\\]|\\.?)*+(?:"|\z)|'(?:[^'\\]|\\.?)*+(?:'|\z)|`(?:[^`\\]|\\.?)*+(?:`|\z))/m
    # Whatever follows "=": Postgres' "Key (email)=(jane smith)", "token = abc".
    # A parenthesized value runs to the last ")" in the message (the value can
    # hold one or span lines), or to the end.
    ASSIGNED = /(?<==)[ \t]*(?:#{QUOTED}[^\s,;)\]}]*|\((?m:.*)\)|\((?m:.*)|[^\s,;)\]}]+)/
    QUOTED_OR_ASSIGNED = /#{ASSIGNED}|#{QUOTED}/

    # Param keys are usually identifiers. Anything else, or an identifier
    # that's really an id or digest, may be data.
    PARAM_KEY = /\A[A-Za-z_][\w\-.]{0,99}\z/
    ID_KEY = /\A(?:\h{8}-\h{4}-\h{4}-\h{4}-\h{12}|(?:0x)?(?=\h*\d)(?=\h*[a-f])\h{8,})\z/i

    module_function

    def scrub_message(message)
      text = UTF8.scrub(message.to_s)
      text = "#{text.byteslice(0, MAX_MESSAGE_BYTES).scrub("")} ..." if text.bytesize > MAX_MESSAGE_BYTES

      text.gsub(QUOTED_OR_ASSIGNED, MASK).gsub(/\S+/) do |token|
        token.split(/(=)/).map { |part| part == "=" ? part : scrub_word(part) }.join
      end
    end

    # A word with its punctuation: kept when plain or already masked.
    def scrub_word(word)
      lead = word[LEADING]
      rest = word.delete_prefix(lead)
      trail = rest[TRAILING]
      core = rest.delete_suffix(trail)
      return word if core.empty? || core == MASK || core.match?(PLAIN_WORD)

      "#{lead}#{MASK}#{trail}"
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

        key = key.to_s
        key = MASK if !key.match?(PARAM_KEY) || key.match?(ID_KEY)
        name = prefix ? "#{prefix}[#{key}]" : key
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
