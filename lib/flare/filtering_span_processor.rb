# frozen_string_literal: true

require "concurrent/atomic/atomic_fixnum"
require "logger"
require "opentelemetry/sdk"

require_relative "deadline"

module Flare
  # BSP-shaped span processor whose filter is `sampled OR marked` instead
  # of BSP's `sampled` (BSP early-returns on RECORD_ONLY spans -- our
  # Path 2 spans have sampled=false so they'd be dropped). Forwards
  # matching spans to a trace exporter on a background worker thread so
  # the exporter never runs on the request/job thread (CAF-3).
  #
  # On every on_finish we also check marker.owner?(trace_id, span_id) and
  # unmark when the owning rack span finishes (CAF-2). Cleanup runs even
  # for spans we don't export.
  #
  # A trace whose rule is judged (capture other than all_requests, or any
  # filters) gets its verdict when its request ends, the owner span
  # finishing. A request the rule doesn't keep has its buffered spans
  # dropped; one it keeps is exported with flare.capture_reason on that
  # span: "slow" or "error" for a failure, "baseline" for a passing request
  # kept for comparison, "match" for an all_requests rule's filtered match.
  # on_start marks a sampled root of such a rule, so a sampled request has
  # an owner too, and a job or server span nested inside it (perform_now)
  # doesn't end it.
  class FilteringSpanProcessor
    SUCCESS = OpenTelemetry::SDK::Trace::Export::SUCCESS
    FAILURE = OpenTelemetry::SDK::Trace::Export::FAILURE
    TIMEOUT = OpenTelemetry::SDK::Trace::Export::TIMEOUT

    DEFAULT_MAX_QUEUE = 5_000
    DEFAULT_FLUSH_INTERVAL = 5      # seconds
    DEFAULT_EXPORT_TIMEOUT = 30     # seconds
    DEFAULT_MARKED_TRACE_GRACE_PERIOD = 1.0 # seconds

    # Passing requests kept per rule in this process while the server asks
    # for a baseline. The server stops asking once it has enough, but only on
    # the next poll; this keeps a busy endpoint from spending the shared
    # upload URLs on passing requests meanwhile.
    BASELINES_PER_RULE = 2

    # judged_rule's answer for a marked trace whose rule the server no longer sends.
    EXPIRED_RULE = :expired

    # Dropped sampled requests remembered so spans that finish after them
    # are dropped too; a sampled span is otherwise kept even after its trace
    # was unmarked. Oldest forgotten first.
    MAX_DROPPED_TRACES = 10_000

    attr_reader :dropped_count, :failed_export_count, :exception_count, :buffer_high_watermark, :max_queue

    # sampler and slo_check enable judged rules: sampler says which rules
    # judge their requests, and slo_check (a MetricSpanProcessor) says
    # whether a finished request failed its SLO with slo_failure(span).
    # Without both, every rule keeps every request it samples.
    def initialize(exporter:, marker:, sampler: nil, slo_check: nil,
                   max_queue: DEFAULT_MAX_QUEUE,
                   flush_interval: DEFAULT_FLUSH_INTERVAL,
                   export_timeout: DEFAULT_EXPORT_TIMEOUT,
                   marked_trace_grace_period: DEFAULT_MARKED_TRACE_GRACE_PERIOD,
                   logger: nil)
      @exporter       = exporter
      @marker         = marker
      @sampler        = sampler
      @slo_check      = slo_check
      @max_queue      = max_queue
      @flush_interval = flush_interval
      @export_timeout = export_timeout
      @marked_trace_grace_period = marked_trace_grace_period.to_f
      @logger         = logger || Logger.new($stderr, level: Logger::WARN)

      @pending_by_trace = {}
      @trace_order      = []
      @pending_count    = 0
      @ready_queue      = []
      @delayed_ready_by_trace = {}
      @mutex            = Mutex.new
      @cond             = ConditionVariable.new
      @stopped          = false
      @active_exports   = 0
      @export_completion_sequence = 0
      @last_export_result = SUCCESS
      @flush_owner      = nil
      @baselines_taken  = {}
      @dropped_traces   = {}
      @pid              = $$

      @dropped_count       = Concurrent::AtomicFixnum.new(0)
      @failed_export_count = Concurrent::AtomicFixnum.new(0)
      @exception_count     = Concurrent::AtomicFixnum.new(0)
      @buffer_high_watermark = Concurrent::AtomicFixnum.new(0)

      start_worker
    end

    def on_start(span, _parent_context)
      return if @sampler.nil? || @slo_check.nil?

      ctx = span.context
      return if !ctx&.trace_flags&.sampled? || !root_span?(span)

      rule_id = span.attributes&.[](Sampler::RULE_ID_ATTRIBUTE)
      return unless @sampler.judged_rule(rule_id)

      @marker.mark(ctx.trace_id, owner_span_id: ctx.span_id, rule_id: rule_id, judged: true)
    rescue StandardError => e
      callback_failed("on_start", e)
    end

    def on_finish(span)
      detect_forking

      ctx = span.context
      sampled = ctx&.trace_flags&.sampled?
      marked  = ctx && @marker.marked?(ctx.trace_id)
      owner_finished = marked && @marker.owner?(ctx.trace_id, ctx.span_id)

      return unless sampled || marked

      span_data = span.respond_to?(:to_span_data) ? span.to_span_data : span
      complete = owner_finished || sampled_completion_span?(span_data)

      rule = judged_rule(ctx.trace_id, marked) if complete
      if rule
        # Only the owner ends the request; a nested job or server span is part of it.
        return enqueue(span_data, complete: false, sampled: sampled) unless owner_finished
        return discard_trace(ctx.trace_id, sampled) if rule == EXPIRED_RULE

        reason = verdict(rule, span_data)
        return discard_trace(ctx.trace_id, sampled) unless reason

        span_data = with_capture_reason(span_data, reason)
      end

      enqueue(
        span_data,
        complete: complete,
        delay: owner_finished ? @marked_trace_grace_period : 0,
        sampled: sampled
      )
    rescue StandardError => e
      callback_failed("on_finish", e)
    end

    def force_flush(timeout: nil)
      detect_forking
      deadline = Deadline.new(timeout)
      return TIMEOUT unless begin_flush(deadline)
      prior_result = @flush_prior_result

      batch = snapshot_for_flush(deadline)
      return TIMEOUT unless batch

      operation = start_flush_export(batch, deadline)
      result = wait_for_flush_export(operation, deadline)
      [prior_result, result].max
    ensure
      finish_flush if @flush_owner == Thread.current
    end

    def shutdown(timeout: nil)
      detect_forking
      deadline = Deadline.new(timeout)
      return TIMEOUT unless lock_before_deadline(deadline)

      begin
        @stopped = true
        @cond.broadcast
      ensure
        @mutex.unlock
      end
      @worker.join(deadline.remaining || 5)
      return TIMEOUT if @worker.alive? || deadline.expired?

      result = force_flush(timeout: deadline.remaining)
      return result unless result == SUCCESS
      return TIMEOUT if deadline.expired?

      exporter_result = @exporter.shutdown(timeout: deadline.remaining) if @exporter.respond_to?(:shutdown)
      return TIMEOUT if deadline.expired?

      exporter_result || SUCCESS
    end

    def buffer_size
      @mutex.synchronize { queued_span_count }
    end

    def reset_buffer_high_watermark
      @buffer_high_watermark.value = buffer_size
    end

    private

    # The SDK calls processors without a rescue, so a bug in a callback would
    # raise into the app's request or job. Count every failure, warn once
    # per process (keyed by pid so forked workers still warn).
    def callback_failed(callback, error)
      @exception_count.increment
      return if @callback_error_warned_pid == $$

      @callback_error_warned_pid = $$
      @logger.warn("[Flare::FilteringSpanProcessor] #{callback} failed: #{error.class}: #{error.message}")
    end

    # Judged traces are always marked: by WebMarkerSubscriber, or by
    # on_start for a sampled root. Returns the rule when it judges its
    # requests, EXPIRED_RULE when a judged rule stopped arriving from the
    # server while the request ran (its filters and mode are gone, so the
    # request can't be judged and is dropped), else nil. A plain
    # all_requests rule that expires keeps the request it already selected.
    def judged_rule(trace_id, marked)
      return nil if !marked || @sampler.nil? || @slo_check.nil?

      entry = @marker.entry(trace_id)
      return nil if entry.nil? || entry.rule_id.nil?

      rule = @sampler.rules.find { |candidate| candidate.id == entry.rule_id }
      if rule.nil?
        return entry.judged ? EXPIRED_RULE : nil
      end

      rule.judged? ? rule : nil
    end

    # A kept trace waiting on its grace period already has its verdict; it
    # waits only for late spans.
    def awaiting_verdict?(trace_id)
      !@delayed_ready_by_trace.key?(trace_id) && !judged_rule(trace_id, @marker.marked?(trace_id)).nil?
    end

    # Why the rule keeps this finished request, or nil to drop it. A request
    # has to match every filter. Then all_requests keeps it, errors keeps an
    # error, and slo_failures keeps a slow or errored request. A request
    # that didn't fail can still be kept as a baseline while the server asks
    # for one.
    def verdict(rule, span_data)
      return nil unless rule.filters.all? { |filter| filter.match?(span_data) }
      return "match" if rule.capture == Sampler::CAPTURE_ALL_REQUESTS

      failure = @slo_check.slo_failure(span_data)
      failure = nil if rule.capture == Sampler::CAPTURE_ERRORS && failure != "error"
      return failure if failure

      "baseline" if rule.baseline && take_baseline(rule.id)
    end

    def take_baseline(rule_id)
      @mutex.synchronize do
        prune_baselines if @baselines_taken.size > 64
        taken = @baselines_taken.fetch(rule_id, 0)
        return false if taken >= BASELINES_PER_RULE

        @baselines_taken[rule_id] = taken + 1
        true
      end
    end

    # Rules last an hour at most, so forget counts for rules the server no
    # longer sends. Caller holds @mutex.
    def prune_baselines
      current = @sampler.rules.map(&:id)
      @baselines_taken = @baselines_taken.select { |rule_id, _| current.include?(rule_id) }
    end

    # The rule doesn't keep the request: drop what was buffered for it and
    # stop following the trace, so spans that finish later are dropped too.
    # Unmarking is enough for a marked trace; a sampled one is remembered.
    def discard_trace(trace_id, sampled)
      @mutex.synchronize do
        take_pending(trace_id)
        @delayed_ready_by_trace.delete(trace_id)
        remember_dropped(trace_id) if sampled
      end
      @marker.unmark(trace_id)
    end

    # Caller holds @mutex.
    def remember_dropped(trace_id)
      @dropped_traces.shift if @dropped_traces.size >= MAX_DROPPED_TRACES
      @dropped_traces[trace_id] = true
    end

    def with_capture_reason(span_data, reason)
      tagged = span_data.dup
      tagged.attributes = (span_data.attributes || {}).merge(Sampler::CAPTURE_REASON_ATTRIBUTE => reason).freeze
      tagged
    end

    # A sampled span of a dropped request is dropped too. Only sampled spans:
    # a sampled trace starts at a local root with a new trace id, so a later
    # request that marks the same id (an unsampled span from a propagated
    # context) is judged on its own.
    def enqueue(span_data, complete:, delay: 0, sampled: false)
      @mutex.synchronize do
        return if @stopped
        return if sampled && @dropped_traces.key?(span_data.trace_id)

        trace_id = span_data.trace_id
        @trace_order << trace_id unless @pending_by_trace.key?(trace_id)
        @pending_by_trace[trace_id] ||= []
        @pending_by_trace[trace_id] << span_data
        @pending_count += 1
        evict_oldest_spans

        if complete
          delay.positive? ? delay_trace_ready(trace_id, delay) : mark_trace_ready(trace_id)
        end
        evict_oldest_spans
        update_buffer_high_watermark
      end
    end

    def worker_loop
      until stopped?
        @mutex.synchronize do
          timeout = next_wait_timeout
          waiting_for_export = @flush_owner || @active_exports.positive?
          @cond.wait(@mutex, timeout) if (@ready_queue.empty? || waiting_for_export) && !@stopped
        end
        drain_and_export
      end
    end

    def stopped?
      @mutex.synchronize { @stopped }
    end

    def drain_and_export
      batch = nil
      @mutex.synchronize do
        promote_due_delayed_traces
        return if @ready_queue.empty? || @flush_owner || @active_exports.positive?

        batch = @ready_queue
        @ready_queue = []
        @active_exports += 1
      end

      result = export_batch(batch, timeout: @export_timeout)
    ensure
      export_finished(result || FAILURE) if batch
    end

    def begin_flush(deadline)
      return false unless lock_before_deadline(deadline)

      begin
        initial_sequence = @export_completion_sequence
        while @flush_owner && @flush_owner != Thread.current
          return false if deadline.expired?

          @cond.wait(@mutex, deadline.remaining)
        end
        @flush_owner = Thread.current

        while @active_exports.positive?
          return false if deadline.expired?

          @cond.wait(@mutex, deadline.remaining)
        end
        @flush_prior_result = if @export_completion_sequence > initial_sequence
          @last_export_result
        else
          SUCCESS
        end
      ensure
        @mutex.unlock
      end
      true
    end

    def finish_flush
      @mutex.synchronize do
        @flush_owner = nil
        @cond.broadcast
      end
    end

    def snapshot_for_flush(deadline)
      return unless lock_before_deadline(deadline)

      begin
        # A failures-only request still in flight has no verdict yet, so its
        # spans stay buffered; everything else goes out now.
        held = @pending_by_trace.select { |trace_id, _| awaiting_verdict?(trace_id) }
        @pending_by_trace.each { |trace_id, spans| @ready_queue.concat(spans) unless held.key?(trace_id) }
        held.clear if @stopped # after shutdown they never get a verdict
        @pending_by_trace.replace(held)
        @trace_order.select! { |trace_id| held.key?(trace_id) }
        @pending_count = held.each_value.sum(&:length)
        unmark_delayed_traces
        @delayed_ready_by_trace.clear
        batch = @ready_queue
        @ready_queue = []
        batch
      ensure
        @mutex.unlock
      end
    end

    def start_flush_export(batch, deadline)
      operation = { done: false, result: nil }
      @mutex.synchronize { @active_exports += 1 }
      Thread.new do
        result = batch.empty? ? SUCCESS : export_batch(batch, timeout: deadline.remaining)
        if result == SUCCESS && !deadline.expired? && @exporter.respond_to?(:force_flush)
          result = @exporter.force_flush(timeout: deadline.remaining)
        end
        result = TIMEOUT if deadline.expired?
        operation[:result] = result
      rescue StandardError => e
        @exception_count.increment
        @logger.warn("[Flare::FilteringSpanProcessor] force flush failed: #{e.class}: #{e.message}")
        operation[:result] = FAILURE
      ensure
        @mutex.synchronize do
          operation[:done] = true
          complete_export(operation[:result])
        end
      end
      operation
    end

    def wait_for_flush_export(operation, deadline)
      @mutex.synchronize do
        until operation[:done]
          return TIMEOUT if deadline.expired?

          @cond.wait(@mutex, deadline.remaining)
        end
      end
      operation[:result]
    end

    def export_batch(batch, timeout:)
      result = @exporter.export(batch, timeout: timeout)
      @failed_export_count.increment if result != SUCCESS
      result
    rescue StandardError => e
      @exception_count.increment
      @logger.warn("[Flare::FilteringSpanProcessor] export failed: #{e.class}: #{e.message}")
      FAILURE
    end

    def export_finished(result)
      @mutex.synchronize do
        complete_export(result)
      end
    end

    def complete_export(result)
      @active_exports -= 1
      @export_completion_sequence += 1
      @last_export_result = result || FAILURE
      @cond.broadcast
    end

    def lock_before_deadline(deadline)
      return @mutex.lock unless deadline.remaining

      until @mutex.try_lock
        return false if deadline.expired?

        sleep([deadline.remaining, 0.001].min)
      end
      true
    end

    def mark_trace_ready(trace_id)
      batch = take_pending(trace_id)
      return unless batch

      @delayed_ready_by_trace.delete(trace_id)
      @ready_queue.concat(batch)
      @cond.signal
    end

    # Removes a trace's buffered spans and returns them. Caller holds @mutex.
    def take_pending(trace_id)
      batch = @pending_by_trace.delete(trace_id)
      return unless batch

      @trace_order.delete(trace_id)
      @pending_count -= batch.length
      batch
    end

    def delay_trace_ready(trace_id, delay)
      @delayed_ready_by_trace[trace_id] = monotonic_now + delay
      @cond.signal
    end

    def promote_due_delayed_traces
      now = monotonic_now
      ready_trace_ids = @delayed_ready_by_trace.select { |_, ready_at| ready_at <= now }.keys
      ready_trace_ids.each do |trace_id|
        # Overflow may have evicted the whole batch, so mark_trace_ready
        # would not clear the entry and next_wait_timeout would return 0 forever.
        @delayed_ready_by_trace.delete(trace_id)
        mark_trace_ready(trace_id)
        @marker.unmark(trace_id)
      end
    end

    def unmark_delayed_traces
      @delayed_ready_by_trace.each_key { |trace_id| @marker.unmark(trace_id) }
    end

    def next_wait_timeout
      next_ready_at = @delayed_ready_by_trace.values.min
      return @flush_interval unless next_ready_at

      [next_ready_at - monotonic_now, 0].max
    end

    def evict_oldest_spans
      while queued_span_count > @max_queue
        trace_id = @trace_order.first
        unless trace_id
          @ready_queue.shift
          @dropped_count.increment
          next
        end

        spans = @pending_by_trace[trace_id]
        if spans.nil? || spans.empty?
          @trace_order.shift
          next
        end

        spans.shift
        @pending_count -= 1
        @dropped_count.increment

        if spans.empty?
          @pending_by_trace.delete(trace_id)
          @trace_order.shift
        end
      end
    end

    def queued_span_count
      @pending_count + @ready_queue.length
    end

    def update_buffer_high_watermark
      current = queued_span_count
      @buffer_high_watermark.update { |previous| current > previous ? current : previous }
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def sampled_completion_span?(span_data)
      root_span?(span_data) || entry_span?(span_data)
    end

    def root_span?(span_data)
      parent_id = span_data.parent_span_id if span_data.respond_to?(:parent_span_id)
      parent_id.nil? ||
        (parent_id.respond_to?(:empty?) && parent_id.empty?) ||
        parent_id == OpenTelemetry::Trace::INVALID_SPAN_ID
    end

    def entry_span?(span_data)
      return false unless span_data.respond_to?(:kind)

      span_data.kind == :server || span_data.kind == :consumer
    end

    def detect_forking
      return if @pid == $$

      # The child only retains the forking thread. Replace synchronization
      # objects so it cannot inherit locks or active-export bookkeeping owned
      # by vanished threads.
      @pid = $$
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @pending_by_trace = {}
      @trace_order = []
      @ready_queue = []
      @delayed_ready_by_trace = {}
      @pending_count = 0
      @active_exports = 0
      @export_completion_sequence = 0
      @last_export_result = SUCCESS
      @flush_prior_result = SUCCESS
      @flush_owner = nil
      @baselines_taken = {}
      @dropped_traces = {}
      @stopped = false
      @worker = nil
      start_worker
    end

    def start_worker
      return if @worker&.alive?

      @worker = Thread.new { worker_loop }
      @worker.name = "flare-filtering-span-processor"
    end
  end
end
