# frozen_string_literal: true

require "concurrent/atomic/atomic_reference"

module Flare
  # Thread-safe pool of presigned R2 PUT URLs the RuleManager fills from
  # the /api/rules response. TraceExporter checks one out before each
  # upload; if the pool is empty (no active rules, no fresh URLs) it
  # returns nil and the exporter gives up on that batch -- caller decides
  # what to do.
  #
  # Each entry is a Hash: { upload_id:, key:, put_url:, expires_at: }.
  # expires_at is a Time; entries past their expiry are skipped on checkout.
  #
  # Fork-safe: after_fork clears the pool so child processes don't reuse
  # parent URLs (each child polls its own copy from /api/rules anyway).
  class UploadUrlPool
    attr_reader :checkouts, :empty_count, :expired_count

    def initialize
      @entries_ref   = Concurrent::AtomicReference.new([].freeze)
      @checkouts     = Concurrent::AtomicFixnum.new(0)
      @empty_count   = Concurrent::AtomicFixnum.new(0)
      @expired_count = Concurrent::AtomicFixnum.new(0)
    end

    def replace(entries)
      normalized = (entries || []).filter_map { |raw| normalize(raw) }
      @entries_ref.set(normalized.freeze)
    end

    def checkout
      now = Time.now
      loop do
        current = @entries_ref.get
        if current.empty?
          @empty_count.increment
          return nil
        end

        candidate, *rest = current
        next_state = rest.freeze
        next unless @entries_ref.compare_and_set(current, next_state)

        if expired?(candidate, now)
          @expired_count.increment
          next # try the next one
        end

        @checkouts.increment
        return candidate
      end
    end

    def size
      @entries_ref.get.length
    end

    def empty?
      size.zero?
    end

    def clear
      @entries_ref.set([].freeze)
    end

    # Drop URLs that have already passed their expires_at. Cheap; safe to
    # call from RuleManager's scheduler in between polls.
    def sweep
      now = Time.now
      current = @entries_ref.get
      live    = current.reject { |e| expired?(e, now) }
      return 0 if live.length == current.length

      @entries_ref.set(live.freeze)
      current.length - live.length
    end

    # Call from Flare.after_fork. Parent's URLs aren't usable from the
    # child's point of view (each child should get its own from a fresh
    # /api/rules poll), so just drop them.
    def after_fork
      clear
    end

    private

    def normalize(raw)
      h = raw.is_a?(Hash) ? raw : nil
      return nil unless h

      upload_id  = h[:upload_id] || h["upload_id"]
      key        = h[:key]       || h["key"]
      put_url    = h[:put_url]   || h["put_url"]
      expires_at = h[:expires_at] || h["expires_at"]
      return nil if upload_id.nil? || key.nil? || put_url.nil?

      expires_at = Time.iso8601(expires_at) if expires_at.is_a?(String)
      { upload_id: upload_id, key: key, put_url: put_url, expires_at: expires_at }
    rescue StandardError
      nil
    end

    def expired?(entry, now)
      entry[:expires_at] && entry[:expires_at] <= now
    end
  end
end
