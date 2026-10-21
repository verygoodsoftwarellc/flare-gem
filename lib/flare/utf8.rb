# frozen_string_literal: true

module Flare
  # Span attributes carry raw request bytes (User-Agent, paths) and SQL, which
  # can hold invalid UTF-8. JSON.generate raises on those, failing the whole
  # export batch, so replace the bad bytes before serializing.
  module UTF8
    def self.scrub(value)
      case value
      when String
        return value if value.ascii_only? || (value.valid_encoding? && value.encoding != Encoding::BINARY)

        value.dup.force_encoding(Encoding::UTF_8).scrub
      when Array then value.map { |v| scrub(v) }
      when Hash then value.to_h { |k, v| [scrub(k), scrub(v)] }
      else value
      end
    end
  end
end
