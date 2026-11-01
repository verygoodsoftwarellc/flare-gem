# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "flare/redis_statement_processor"

class RedisStatementProcessorTest < Minitest::Test
  class Capture
    attr_reader :spans

    def initialize = @spans = []
    def on_start(_span, _context); end
    def on_finish(span) = @spans << span.to_span_data
    def force_flush(timeout: nil) = 0
    def shutdown(timeout: nil) = 0
  end

  def setup
    @capture = Capture.new
    @provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    @provider.add_span_processor(Flare::RedisStatementProcessor.new)
    @provider.add_span_processor(@capture)
    @tracer = @provider.tracer("test")
  end

  def statement_for(name, attributes)
    @tracer.in_span(name, attributes: attributes, kind: :client) {}
    @capture.spans.last.attributes["db.statement"]
  end

  def test_masks_a_redis_statement_before_any_processor_sees_the_finished_span
    assert_equal "SET session:?", statement_for("SET", { "db.system" => "redis", "db.statement" => "SET session:abc hunter2" })
  end

  def test_only_a_pipeline_is_read_line_by_line
    statement = "SET a:1 x\nGET secret:hunter2"
    assert_equal "SET a:?", statement_for("SET", { "db.system" => "redis", "db.statement" => statement })
    assert_equal "SET ?\nGET ?", statement_for("PIPELINED", { "db.system" => "redis", "db.statement" => statement })
  end

  def test_leaves_other_spans_alone
    assert_equal "SELECT 'a'", statement_for("q", { "db.system" => "postgresql", "db.statement" => "SELECT 'a'" })
    assert_nil statement_for("GET", { "db.system" => "redis" })
  end

  def test_an_error_while_masking_leaves_no_statement_behind
    Flare::StoreStatement.stub(:redis, ->(*, **) { raise "boom" }) do
      assert_equal "?", statement_for("SET", { "db.system" => "redis", "db.statement" => "SET a:1 hunter2" })
    end
  end
end
