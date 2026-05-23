# frozen_string_literal: true

require "opentelemetry/sdk"

module Flare
  # Path 2: ActiveSupport::Notifications subscriber that fires on
  # `start_processing.action_controller`, after Rails has routed to a
  # controller#action. At that point the rack server span's start
  # attributes don't yet carry code.namespace/code.function -- only the
  # ActionPack instrumentation adds them, and Flare::Sampler's start-time
  # decision (RECORD_ONLY) was already locked in.
  #
  # The subscriber consults the same sampler's rule set, finds any whose
  # match_attributes match the now-known controller/action, applies the
  # deterministic trace_id_ratio gate (CAF-1: no rate bypass on Path 2),
  # and on pass calls marker.mark(trace_id, owner_span_id:, rule_id:).
  # FilteringSpanProcessor then forwards every span in the trace to the
  # exporter and unmarks when the owner (this rack span) finishes.
  class WebMarkerSubscriber
    NOTIFICATION = "start_processing.action_controller"

    def initialize(sampler:, marker:)
      @sampler = sampler
      @marker = marker
    end

    def start
      @subscriber = ActiveSupport::Notifications.subscribe(NOTIFICATION) do |*, payload|
        handle(payload)
      end
      self
    end

    def stop
      ActiveSupport::Notifications.unsubscribe(@subscriber) if @subscriber
      @subscriber = nil
      self
    end

    # Public for tests so they don't have to drive ActiveSupport::Notifications.
    # current_span lets tests inject a context; in production it's the
    # rack server span on the current thread.
    def handle(payload, current_span: OpenTelemetry::Trace.current_span)
      return unless current_span
      ctx = current_span.context
      return unless ctx && ctx.valid?

      attrs = candidate_attributes(payload)
      return if attrs.empty?

      @sampler.rules.each do |rule|
        next unless matches?(rule, attrs)
        next unless @sampler.trace_id_ratio(ctx.trace_id) < rule.rate

        current_span.set_attribute(Flare::Sampler::RULE_ID_ATTRIBUTE, rule.id) if current_span.respond_to?(:set_attribute)
        @marker.mark(ctx.trace_id, owner_span_id: ctx.span_id, rule_id: rule.id)
        break
      end
    end

    private

    def candidate_attributes(payload)
      controller = payload[:controller] || payload["controller"]
      action     = payload[:action]     || payload["action"]
      {
        "code.namespace" => controller,
        "code.function"  => action
      }.compact
    end

    def matches?(rule, attrs)
      rule.match_attributes.all? { |k, v| attrs[k] == v }
    end
  end
end
