# frozen_string_literal: true

require "opentelemetry/sdk"

require_relative "store_statement"

module Flare
  # Replaces a Redis statement with its shape as the span starts, so raw arguments
  # never reach a finished span: not the development database, not an export, and
  # not another exporter the app has added. The Redis instrumentation sends the
  # key only when it's told to include arguments, which Flare does for this.
  class RedisStatementProcessor
    STATEMENT = "db.statement"
    SUCCESS = OpenTelemetry::SDK::Trace::Export::SUCCESS

    def on_start(span, _parent_context)
      return unless span.kind == :client

      attributes = span.attributes
      return unless attributes && attributes["db.system"] == "redis"

      statement = attributes[STATEMENT]
      return unless statement

      span.set_attribute(STATEMENT, masked(statement, span))
    rescue StandardError
      span.set_attribute(STATEMENT, StoreStatement::PLACEHOLDER) if span.respond_to?(:set_attribute)
    end

    def on_finish(_span); end

    def force_flush(timeout: nil)
      SUCCESS
    end

    def shutdown(timeout: nil)
      SUCCESS
    end

    private

    def masked(statement, span)
      StoreStatement.redis(statement, pipelined: span.name == "PIPELINED")
    rescue StandardError
      StoreStatement::PLACEHOLDER
    end
  end
end
