# frozen_string_literal: true

require "concurrent/map"
require "concurrent/atomic/atomic_fixnum"

module Flare
  # Thread-safe registry of trace_ids that Path 2 (the WebMarkerSubscriber)
  # has marked for export. FilteringSpanProcessor checks marked? on every
  # on_finish; matching spans get forwarded to the trace exporter, the rest
  # are dropped.
  #
  # Each entry records the OWNER span_id (the local rack server span the
  # subscriber was inside when it marked the trace). Cleanup is keyed on
  # the owner finishing, not the trace root finishing -- remote-parented
  # rack spans aren't trace roots, and child spans can outlive their parent
  # in OTel, so root-driven cleanup would leak on the dominant production
  # case (web app behind a load balancer or service mesh).
  #
  # Bounded by:
  #   - sweep(): drops entries older than max_age (default 5 min) so a rack
  #     span that never finishes (process killed mid-request, exception path
  #     that skips ensure) doesn't leak forever.
  #   - hard ceiling at max_entries (default 10k): on overflow, drop oldest
  #     10% by marked_at.
  class Marker
    Entry = Struct.new(:owner_span_id, :rule_id, :marked_at, keyword_init: true)

    DEFAULT_MAX_ENTRIES = 10_000
    DEFAULT_MAX_AGE = 5 * 60 # seconds

    attr_reader :evicted_count

    def initialize(max_entries: DEFAULT_MAX_ENTRIES, max_age: DEFAULT_MAX_AGE)
      @entries = Concurrent::Map.new
      @max_entries = max_entries
      @max_age = max_age
      @evicted_count = Concurrent::AtomicFixnum.new(0)
    end

    def mark(trace_id, owner_span_id:, rule_id:)
      @entries[trace_id] = Entry.new(
        owner_span_id: owner_span_id,
        rule_id: rule_id,
        marked_at: monotonic_now
      )
      maybe_evict_oldest
    end

    def marked?(trace_id)
      @entries.key?(trace_id)
    end

    # True only when span_id matches the marker's owner -- the rack span
    # that originally marked this trace. Used by FilteringSpanProcessor to
    # decide when to unmark (only when that exact span finishes, not on
    # every span that happens to have this trace_id).
    def owner?(trace_id, span_id)
      entry = @entries[trace_id]
      !entry.nil? && entry.owner_span_id == span_id
    end

    def rule_id(trace_id)
      entry = @entries[trace_id]
      entry&.rule_id
    end

    def unmark(trace_id)
      @entries.delete(trace_id)
    end

    def size
      @entries.size
    end

    # Drop entries older than max_age. Call periodically (the RuleManager's
    # scheduler is the natural place) to handle the rack-span-never-finishes
    # leak case (CAF-7).
    def sweep
      threshold = monotonic_now - @max_age
      evicted = 0
      @entries.each_pair do |trace_id, entry|
        if entry.marked_at < threshold
          @entries.delete(trace_id)
          evicted += 1
        end
      end
      @evicted_count.increment(evicted) if evicted.positive?
      evicted
    end

    private

    def maybe_evict_oldest
      return if @entries.size <= @max_entries

      to_drop = (@max_entries * 0.1).ceil
      sorted = @entries.each_pair.to_a.sort_by { |_, entry| entry.marked_at }
      sorted.first(to_drop).each { |trace_id, _| @entries.delete(trace_id) }
      @evicted_count.increment(to_drop)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
