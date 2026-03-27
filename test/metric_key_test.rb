# frozen_string_literal: true

require_relative "test_helper"
require "flare/metric_key"

class MetricKeyTest < Minitest::Test
  def test_equality_with_same_values
    time = Time.now
    key1 = Flare::MetricKey.new(
      bucket: time,
      namespace: "web",
      service: "rails",
      target: "UsersController",
      operation: "show"
    )
    key2 = Flare::MetricKey.new(
      bucket: time,
      namespace: "web",
      service: "rails",
      target: "UsersController",
      operation: "show"
    )

    assert_equal key1, key2
    assert key1.eql?(key2)
    assert_equal key1.hash, key2.hash
  end

  def test_inequality_with_different_values
    time = Time.now
    key1 = Flare::MetricKey.new(
      bucket: time,
      namespace: "web",
      service: "rails",
      target: "UsersController",
      operation: "show"
    )
    key2 = Flare::MetricKey.new(
      bucket: time,
      namespace: "web",
      service: "rails",
      target: "UsersController",
      operation: "index"
    )

    refute_equal key1, key2
    refute key1.eql?(key2)
  end

  def test_works_as_hash_key
    time = Time.now
    key1 = Flare::MetricKey.new(
      bucket: time,
      namespace: "web",
      service: "rails",
      target: "UsersController",
      operation: "show"
    )
    key2 = Flare::MetricKey.new(
      bucket: time,
      namespace: "web",
      service: "rails",
      target: "UsersController",
      operation: "show"
    )

    hash = {}
    hash[key1] = "value1"

    assert_equal "value1", hash[key2]
  end

  def test_frozen_strings
    key = Flare::MetricKey.new(
      bucket: Time.now,
      namespace: "web",
      service: "rails",
      target: "UsersController",
      operation: "show"
    )

    assert key.namespace.frozen?
    assert key.service.frozen?
    assert key.target.frozen?
    assert key.operation.frozen?
  end

  def test_nil_target
    key = Flare::MetricKey.new(
      bucket: Time.now,
      namespace: "db",
      service: "pg",
      target: nil,
      operation: "SELECT"
    )

    assert_nil key.target
  end

  def test_to_h
    time = Time.now
    key = Flare::MetricKey.new(
      bucket: time,
      namespace: "web",
      service: "rails",
      target: "UsersController",
      operation: "show"
    )

    expected = {
      bucket: time,
      namespace: "web",
      service: "rails",
      target: "UsersController",
      operation: "show"
    }

    assert_equal expected, key.to_h
  end
end
