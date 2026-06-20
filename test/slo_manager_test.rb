# frozen_string_literal: true

require_relative "test_helper"
require "flare/slo_manager"

class SloManagerTest < Minitest::Test
  def setup
    @manager = Flare::SloManager.new
  end

  def test_empty_by_default_returns_nil
    assert_nil @manager.threshold_for(namespace: "web", service: "rails", target: "X#y")
    assert_equal({}, @manager.defaults)
    assert_equal({}, @manager.operations)
  end

  def test_namespace_default_used_when_no_override
    @manager.update(defaults: { "web" => 1000, "job" => 60000 })

    assert_equal 1000, @manager.threshold_for(namespace: "web", service: "rails", target: "X#y")
    assert_equal 60000, @manager.threshold_for(namespace: "job", service: "sidekiq", target: "MyJob")
  end

  def test_per_op_override_takes_precedence
    @manager.update(
      defaults: { "web" => 1000 },
      operations: [
        { "namespace" => "web", "service" => "rails", "target" => "FeedsController#serve_feed", "threshold_ms" => 250 }
      ]
    )

    assert_equal 250, @manager.threshold_for(namespace: "web", service: "rails", target: "FeedsController#serve_feed")
    # Other operations still fall back to the namespace default.
    assert_equal 1000, @manager.threshold_for(namespace: "web", service: "rails", target: "Other#index")
  end

  def test_nil_when_namespace_default_cleared
    @manager.update(defaults: { "web" => 1000 }) # job omitted -> untracked

    assert_nil @manager.threshold_for(namespace: "job", service: "sidekiq", target: "MyJob")
  end

  def test_update_is_atomic_swap
    @manager.update(defaults: { "web" => 1000 })
    @manager.update(defaults: { "web" => 500 }, operations: [])

    assert_equal 500, @manager.threshold_for(namespace: "web", service: "rails", target: "X#y")
  end

  def test_symbol_keys_accepted
    @manager.update(
      defaults: { web: 800 },
      operations: [{ namespace: "web", service: "rails", target: "X#y", threshold_ms: 100 }]
    )

    assert_equal 100, @manager.threshold_for(namespace: "web", service: "rails", target: "X#y")
    assert_equal 800, @manager.threshold_for(namespace: "web", service: "rails", target: "Z#a")
  end

  def test_malformed_entries_are_dropped
    @manager.update(
      defaults: { "web" => 1000, "job" => nil, "bad" => "abc" },
      operations: [
        { "namespace" => "web", "service" => "rails", "target" => "Good#ok", "threshold_ms" => 250 },
        { "namespace" => "web", "service" => "rails" }, # missing target + threshold
        { "namespace" => "web", "service" => "rails", "target" => "NoThreshold#x" },
        "not a hash"
      ]
    )

    assert_equal({ "web" => 1000 }, @manager.defaults)
    assert_equal 250, @manager.threshold_for(namespace: "web", service: "rails", target: "Good#ok")
    assert_equal 1, @manager.operations.size
  end

  def test_non_positive_thresholds_dropped
    @manager.update(
      defaults: { "web" => 0 },
      operations: [{ "namespace" => "web", "service" => "rails", "target" => "X#y", "threshold_ms" => -5 }]
    )

    assert_equal({}, @manager.defaults)
    assert_nil @manager.threshold_for(namespace: "web", service: "rails", target: "X#y")
  end

  def test_string_numeric_threshold_coerced
    @manager.update(defaults: { "web" => "1000" })

    assert_equal 1000, @manager.threshold_for(namespace: "web", service: "rails", target: "X#y")
  end

  def test_update_with_nils_resets_to_empty
    @manager.update(defaults: { "web" => 1000 })
    @manager.update

    assert_equal({}, @manager.defaults)
    assert_nil @manager.threshold_for(namespace: "web", service: "rails", target: "X#y")
  end
end
