# frozen_string_literal: true

require_relative "test_helper"
require "flare/marker"

class MarkerTest < Minitest::Test
  def setup
    @marker = Flare::Marker.new
  end

  def test_mark_then_marked_true
    @marker.mark("trace-1", owner_span_id: "span-a", rule_id: 7)
    assert @marker.marked?("trace-1")
  end

  def test_marked_false_for_unknown_trace
    refute @marker.marked?("nope")
  end

  def test_unmark_removes_the_entry
    @marker.mark("trace-1", owner_span_id: "span-a", rule_id: 7)
    @marker.unmark("trace-1")
    refute @marker.marked?("trace-1")
  end

  def test_rule_id_returns_the_marked_rule
    @marker.mark("trace-1", owner_span_id: "span-a", rule_id: 7)
    assert_equal 7, @marker.rule_id("trace-1")
    assert_nil @marker.rule_id("trace-other")
  end

  def test_owner_true_only_for_matching_span_id
    @marker.mark("trace-1", owner_span_id: "span-a", rule_id: 7)
    assert @marker.owner?("trace-1", "span-a")
    refute @marker.owner?("trace-1", "span-b")
    refute @marker.owner?("trace-other", "span-a")
  end

  def test_two_traces_with_separate_owners
    @marker.mark("trace-1", owner_span_id: "span-a", rule_id: 1)
    @marker.mark("trace-2", owner_span_id: "span-b", rule_id: 2)

    assert @marker.owner?("trace-1", "span-a")
    assert @marker.owner?("trace-2", "span-b")
    refute @marker.owner?("trace-1", "span-b")
    refute @marker.owner?("trace-2", "span-a")
  end

  def test_sweep_evicts_entries_older_than_max_age
    marker = Flare::Marker.new(max_age: 0.05) # 50ms
    marker.mark("old", owner_span_id: "s", rule_id: 1)
    sleep 0.1
    marker.mark("new", owner_span_id: "s", rule_id: 2)

    evicted = marker.sweep

    assert_equal 1, evicted
    refute marker.marked?("old")
    assert marker.marked?("new")
  end

  def test_hard_ceiling_drops_oldest_ten_percent_on_overflow
    marker = Flare::Marker.new(max_entries: 10)
    11.times { |i| marker.mark("trace-#{i}", owner_span_id: "s#{i}", rule_id: 1) }

    # 10% of 10 = 1, ceil(1) = 1 dropped on the 11th mark
    assert_equal 10, marker.size
    refute marker.marked?("trace-0") # oldest dropped
    assert marker.marked?("trace-10") # newest kept
  end

  def test_size_reflects_mark_and_unmark
    assert_equal 0, @marker.size
    @marker.mark("a", owner_span_id: "s", rule_id: 1)
    @marker.mark("b", owner_span_id: "s", rule_id: 1)
    assert_equal 2, @marker.size
    @marker.unmark("a")
    assert_equal 1, @marker.size
  end
end
