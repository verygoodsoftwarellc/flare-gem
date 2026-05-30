# frozen_string_literal: true

require "socket"

require_relative "version"

module Flare
  # Single source of truth for the headers that identify this client and its
  # version to the Flare API. The server parses the gem version out of the
  # User-Agent ("Flare Ruby/X.Y.Z") to gate version-dependent features, and
  # uses the X-Client-* headers to build a per-client picture.
  #
  # Safe to send on any request that targets the Flare API (metrics POST,
  # rules GET, trace-notify POST). Do NOT send these on the presigned R2 blob
  # PUT -- they're meaningless to R2 and can invalidate the signed-header set.
  #
  # Excludes Authorization / Flare-Project / Flare-Environment -- callers add
  # those since they're request- or context-specific.
  module ClientHeaders
    USER_AGENT = "Flare Ruby/#{Flare::VERSION}"

    def self.to_h
      {
        "User-Agent"                => USER_AGENT,
        "X-Client-Language"         => "ruby",
        "X-Client-Language-Version" => RUBY_VERSION,
        "X-Client-Platform"         => RUBY_PLATFORM,
        "X-Client-Pid"              => Process.pid.to_s,
        "X-Client-Hostname"         => hostname
      }
    end

    def self.hostname
      Socket.gethostname
    rescue StandardError
      "unknown"
    end
  end
end
