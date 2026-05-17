# frozen_string_literal: true

require_relative "test_helper"
require "flare/sampler"
require "flare/marker"
require "flare/web_marker_subscriber"

class WebMarkerSubscriberTest < Minitest::Test
  def setup
    @sampler = Flare::Sampler.new
    @marker  = Flare::Marker.new
    @subscriber = Flare::WebMarkerSubscriber.new(sampler: @sampler, marker: @marker)
    @span = MockSpan.new(trace_id: "trace-1", span_id: "rack-span")
  end

  def test_marks_when_controller_action_matches_a_rule_and_ratio_passes
    @sampler.update_rules([rule(id: 9, controller: "UsersController", action: "show", rate: 1.0)])

    @subscriber.handle(payload(controller: "UsersController", action: "show"), current_span: @span)

    assert @marker.marked?("trace-1")
    assert @marker.owner?("trace-1", "rack-span")
    assert_equal 9, @marker.rule_id("trace-1")
  end

  def test_does_not_mark_when_no_rule_matches
    @sampler.update_rules([rule(id: 9, controller: "OtherController", action: "show", rate: 1.0)])
    @subscriber.handle(payload(controller: "UsersController", action: "show"), current_span: @span)

    refute @marker.marked?("trace-1")
  end

  def test_does_not_mark_when_ratio_exceeds_rate
    @sampler.update_rules([rule(id: 9, controller: "UsersController", action: "show", rate: 0.0)])
    @subscriber.handle(payload(controller: "UsersController", action: "show"), current_span: @span)

    refute @marker.marked?("trace-1")
  end

  def test_no_op_when_no_current_span
    @sampler.update_rules([rule(id: 9, controller: "UsersController", action: "show", rate: 1.0)])
    @subscriber.handle(payload(controller: "UsersController", action: "show"), current_span: nil)

    refute @marker.marked?("trace-1")
  end

  def test_no_op_when_payload_lacks_controller_or_action
    @sampler.update_rules([rule(id: 9, controller: "UsersController", action: "show", rate: 1.0)])
    @subscriber.handle({}, current_span: @span)

    refute @marker.marked?("trace-1")
  end

  def test_sets_flare_rule_id_attribute_on_the_owner_span
    @sampler.update_rules([rule(id: 9, controller: "UsersController", action: "show", rate: 1.0)])

    @subscriber.handle(payload(controller: "UsersController", action: "show"), current_span: @span)

    assert_equal 9, @span.attributes[Flare::Sampler::RULE_ID_ATTRIBUTE]
  end

  def test_only_marks_for_the_first_matching_rule
    @sampler.update_rules([
      rule(id: 1, controller: "UsersController", action: "show", rate: 1.0),
      rule(id: 2, controller: "UsersController", action: "show", rate: 1.0)
    ])

    @subscriber.handle(payload(controller: "UsersController", action: "show"), current_span: @span)

    assert_equal 1, @marker.rule_id("trace-1")
  end

  private

  def rule(id:, controller:, action:, rate:)
    { "id" => id, "match_attributes" => { "code.namespace" => controller, "code.function" => action }, "rate" => rate }
  end

  def payload(controller:, action:)
    { controller: controller, action: action }
  end

  class MockSpan
    attr_reader :attributes

    def initialize(trace_id:, span_id:)
      @attributes = {}
      @context = MockContext.new(trace_id, span_id)
    end

    def context = @context

    def set_attribute(key, value)
      @attributes[key] = value
    end
  end

  MockContext = Struct.new(:trace_id, :span_id) do
    def valid?
      true
    end
  end
end
