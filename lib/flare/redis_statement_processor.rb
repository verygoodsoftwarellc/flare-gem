# frozen_string_literal: true

require "opentelemetry/sdk"

require_relative "store_statement"

module Flare
  # Replaces a Redis statement with its shape as the span starts, so raw arguments
  # never reach a finished span: not the development database, not an export, and
  # not another exporter the app has added. The Redis instrumentation sends the
  # key only when it's told to include arguments, which Flare does for this.
  class RedisStatementProcessor < OpenTelemetry::SDK::Trace::SpanProcessor
    STATEMENT = "db.statement"

    def on_start(span, _parent_context)
      return unless span.kind == :client

      attributes = span.attributes
      return unless attributes && StoreStatement.redis_system?(attributes["db.system"])

      statement = attributes[STATEMENT]
      return unless statement

      span.set_attribute(STATEMENT, StoreStatement.redis(statement, pipelined: span.name == "PIPELINED"))
    rescue StandardError
      span.set_attribute(STATEMENT, StoreStatement::PLACEHOLDER) if span.respond_to?(:set_attribute)
    end
  end
end
