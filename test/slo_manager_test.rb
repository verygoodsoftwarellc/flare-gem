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
    assert_equal({}, @manager.overrides)
  end

  def test_namespace_only_rule_is_the_default
    @manager.update([
      { "namespace" => "web", "threshold_ms" => 1000 },
      { "namespace" => "job", "threshold_ms" => 60000 }
    ])

    assert_equal 1000, @manager.threshold_for(namespace: "web", service: "rails", target: "X#y")
    assert_equal 60000, @manager.threshold_for(namespace: "job", service: "sidekiq", target: "MyJob")
  end

  def test_full_rule_is_an_override_and_takes_precedence
    @manager.update([
      { "namespace" => "web", "threshold_ms" => 1000 },
      { "namespace" => "web", "service" => "rails", "target" => "FeedsController#serve_feed", "threshold_ms" => 250 }
    ])

    assert_equal 250, @manager.threshold_for(namespace: "web", service: "rails", target: "FeedsController#serve_feed")
    # Other operations still fall back to the namespace default.
    assert_equal 1000, @manager.threshold_for(namespace: "web", service: "rails", target: "Other#index")
  end

  def test_nil_when_namespace_has_no_default
    @manager.update([{ "namespace" => "web", "threshold_ms" => 1000 }]) # job untracked

    assert_nil @manager.threshold_for(namespace: "job", service: "sidekiq", target: "MyJob")
  end

  def test_update_is_atomic_swap
    @manager.update([{ "namespace" => "web", "threshold_ms" => 1000 }])
    @manager.update([{ "namespace" => "web", "threshold_ms" => 500 }])

    assert_equal 500, @manager.threshold_for(namespace: "web", service: "rails", target: "X#y")
  end

  def test_symbol_keys_accepted
    @manager.update([
      { namespace: "web", threshold_ms: 800 },
      { namespace: "web", service: "rails", target: "X#y", threshold_ms: 100 }
    ])

    assert_equal 100, @manager.threshold_for(namespace: "web", service: "rails", target: "X#y")
    assert_equal 800, @manager.threshold_for(namespace: "web", service: "rails", target: "Z#a")
  end

  def test_malformed_rules_are_dropped
    @manager.update([
      { "namespace" => "web", "threshold_ms" => 1000 },
      { "namespace" => "web", "service" => "rails", "target" => "Good#ok", "threshold_ms" => 250 },
      { "namespace" => "web", "service" => "rails", "threshold_ms" => 300 }, # partial: service but no target
      { "namespace" => "web", "service" => "rails", "target" => "NoThreshold#x" }, # no threshold
      { "threshold_ms" => 500 }, # no namespace
      "not a hash"
    ])

    assert_equal({ "web" => 1000 }, @manager.defaults)
    assert_equal 250, @manager.threshold_for(namespace: "web", service: "rails", target: "Good#ok")
    assert_equal 1, @manager.overrides.size
  end

  def test_non_positive_thresholds_dropped
    @manager.update([
      { "namespace" => "web", "threshold_ms" => 0 },
      { "namespace" => "web", "service" => "rails", "target" => "X#y", "threshold_ms" => -5 }
    ])

    assert_equal({}, @manager.defaults)
    assert_nil @manager.threshold_for(namespace: "web", service: "rails", target: "X#y")
  end

  def test_string_numeric_threshold_coerced
    @manager.update([{ "namespace" => "web", "threshold_ms" => "1000" }])

    assert_equal 1000, @manager.threshold_for(namespace: "web", service: "rails", target: "X#y")
  end

  def test_nil_or_empty_rules_resets_to_empty
    @manager.update([{ "namespace" => "web", "threshold_ms" => 1000 }])
    @manager.update(nil)

    assert_equal({}, @manager.defaults)
    assert_nil @manager.threshold_for(namespace: "web", service: "rails", target: "X#y")
  end

  def test_slow_when_over_threshold_and_not_errored
    @manager.update([{ "namespace" => "web", "threshold_ms" => 100 }])

    assert @manager.slow?(namespace: "web", service: "rails", target: "X#y", duration_ms: 150, error: false)
  end

  def test_not_slow_when_under_threshold
    @manager.update([{ "namespace" => "web", "threshold_ms" => 100 }])

    refute @manager.slow?(namespace: "web", service: "rails", target: "X#y", duration_ms: 50, error: false)
  end

  def test_not_slow_when_errored_even_if_over_threshold
    @manager.update([{ "namespace" => "web", "threshold_ms" => 100 }])

    refute @manager.slow?(namespace: "web", service: "rails", target: "X#y", duration_ms: 150, error: true)
  end

  def test_not_slow_when_untracked
    refute @manager.slow?(namespace: "web", service: "rails", target: "X#y", duration_ms: 5000, error: false)
  end
end
