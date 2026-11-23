# frozen_string_literal: true

require_relative "test_helper"
require "flare/trace_filter"

class TraceFilterTest < Minitest::Test
  Span = Struct.new(:kind, :attributes, :start_timestamp, :end_timestamp, keyword_init: true)

  # ----- Building ----------------------------------------------------------

  def test_builds_each_known_field_and_op
    [
      { "field" => "http.method", "op" => "in", "value" => ["GET"] },
      { "field" => "url.path", "op" => "prefix", "value" => "/a" },
      { "field" => "url.path", "op" => "equals", "value" => "/a" },
      { "field" => "url.path", "op" => "glob", "value" => "/a/*" },
      { "field" => "url.query_param", "op" => "present", "name" => "page" },
      { "field" => "url.query_param", "op" => "equals", "name" => "page", "value" => "2" },
      { "field" => "http.status_code", "op" => "between", "value" => [500, 599] },
      { "field" => "duration_ms", "op" => "between", "value" => [500, nil] }
    ].each do |raw|
      assert Flare::TraceFilter.build(raw), "expected #{raw.inspect} to build"
    end
  end

  def test_unknown_field_or_op_does_not_build
    assert_nil Flare::TraceFilter.build({ "field" => "user.id", "op" => "equals", "value" => "1" })
    assert_nil Flare::TraceFilter.build({ "field" => "url.path", "op" => "regex", "value" => ".*" })
    assert_nil Flare::TraceFilter.build({ "field" => "http.method", "op" => "between", "value" => [1, 2] })
  end

  def test_malformed_values_do_not_build
    assert_nil Flare::TraceFilter.build({ "field" => "http.method", "op" => "in", "value" => [] })
    assert_nil Flare::TraceFilter.build({ "field" => "http.method", "op" => "in", "value" => "GET" })
    assert_nil Flare::TraceFilter.build({ "field" => "url.path", "op" => "prefix", "value" => "" })
    assert_nil Flare::TraceFilter.build({ "field" => "url.query_param", "op" => "present" })
    assert_nil Flare::TraceFilter.build({ "field" => "http.status_code", "op" => "between", "value" => [599, 500] })
    assert_nil Flare::TraceFilter.build({ "field" => "duration_ms", "op" => "between", "value" => [1] })
    assert_nil Flare::TraceFilter.build({ "field" => "duration_ms", "op" => "between", "value" => ["1", nil] })
    assert_nil Flare::TraceFilter.build({ "field" => "url.path", "op" => "prefix", "value" => "/a", "negate" => "yes" })
    assert_nil Flare::TraceFilter.build("url.path")
  end

  def test_null_negate_means_false
    filter = Flare::TraceFilter.build({ "field" => "url.path", "op" => "prefix", "value" => "/a", "negate" => nil })

    assert filter.match?(web(path: "/a/b"))
  end

  # Codex review: one malformed parameter made the whole query parse as empty,
  # so a negated "present" filter matched a request that had the parameter.
  def test_malformed_param_does_not_hide_the_others
    absent = build_query("present", "preview", negate: true)
    equals = build_query("equals", "preview", "1")

    refute absent.match?(web(query: "bad=%ZZ&preview=1"))
    assert equals.match?(web(query: "bad=%ZZ&preview=1"))
    assert absent.match?(web(query: "bad=%ZZ"))
  end

  def test_symbol_keys_build_too
    filter = Flare::TraceFilter.build({ field: "url.path", op: "prefix", value: "/a", negate: true })

    refute filter.match?(web(path: "/a/b"))
    assert filter.match?(web(path: "/b"))
  end

  # ----- http.method -------------------------------------------------------

  def test_method_in_matches_case_insensitively
    filter = build("http.method", "in", ["get", "POST"])

    assert filter.match?(web(method: "GET"))
    assert filter.match?(web(attributes: { "http.request.method" => "post" }))
    refute filter.match?(web(method: "DELETE"))
    refute filter.match?(web(attributes: {}))
  end

  # ----- url.path ----------------------------------------------------------

  def test_path_prefix_equals_and_glob
    assert build("url.path", "prefix", "/passages/").match?(web(path: "/passages/12"))
    refute build("url.path", "prefix", "/passages/").match?(web(path: "/sermons/12"))

    assert build("url.path", "equals", "/passages").match?(web(path: "/passages"))
    refute build("url.path", "equals", "/passages").match?(web(path: "/passages/1"))

    glob = build("url.path", "glob", "/accounts/*/passages")
    assert glob.match?(web(path: "/accounts/9/passages"))
    refute glob.match?(web(path: "/accounts/9/x/passages")), "* stays within one segment"
    assert build("url.path", "glob", "/accounts/**/passages").match?(web(path: "/accounts/9/x/passages"))
  end

  def test_path_falls_back_to_http_target_without_its_query
    filter = build("url.path", "equals", "/passages")

    assert filter.match?(web(attributes: { "http.target" => "/passages?page=2" }))
  end

  # ----- url.query_param ---------------------------------------------------

  def test_query_param_present_and_equals
    present = build_query("present", "page")
    equals = build_query("equals", "page", "2")

    assert present.match?(web(query: "page=2&q=x"))
    assert present.match?(web(query: "page"))
    refute present.match?(web(query: "q=x"))
    refute present.match?(web(attributes: { "url.path" => "/passages" }))

    assert equals.match?(web(query: "page=2"))
    refute equals.match?(web(query: "page=3"))
  end

  def test_repeated_query_keys_match_if_any_value_does
    assert build_query("equals", "tag", "b").match?(web(query: "tag=a&tag=b"))
  end

  def test_query_param_reads_http_target_when_url_query_is_missing
    assert build_query("equals", "page", "2").match?(web(attributes: { "http.target" => "/passages?page=2" }))
  end

  def test_param_with_a_malformed_value_is_still_present
    assert build_query("present", "page").match?(web(query: "page=%E0%A4%A"))
    refute build_query("equals", "page", "2").match?(web(query: "page=%E0%A4%A"))
  end

  # ----- http.status_code --------------------------------------------------

  def test_status_between_is_inclusive_and_open_ended
    server_errors = build("http.status_code", "between", [500, 599])
    not_found = build("http.status_code", "between", [404, 404])

    assert server_errors.match?(web(status: 500))
    assert server_errors.match?(web(attributes: { "http.response.status_code" => "503" }))
    refute server_errors.match?(web(status: 404))
    assert not_found.match?(web(status: 404))
    refute server_errors.match?(web(attributes: {})), "no status is no match"
    assert build("http.status_code", "between", [400, nil]).match?(web(status: 503))
  end

  # ----- duration_ms -------------------------------------------------------

  def test_duration_between_greater_less_and_range
    assert build("duration_ms", "between", [500, nil]).match?(web(duration_ms: 500))
    refute build("duration_ms", "between", [500, nil]).match?(web(duration_ms: 499))
    assert build("duration_ms", "between", [nil, 500]).match?(web(duration_ms: 120))
    assert build("duration_ms", "between", [500, 1000]).match?(web(duration_ms: 750))
    refute build("duration_ms", "between", [500, 1000]).match?(web(duration_ms: 1001))
  end

  def test_duration_matches_jobs
    assert build("duration_ms", "between", [1000, nil]).match?(job(duration_ms: 2500))
  end

  # ----- negate and jobs ---------------------------------------------------

  def test_negate_flips_the_result
    filter = build("url.path", "prefix", "/admin", negate: true)

    refute filter.match?(web(path: "/admin/users"))
    assert filter.match?(web(path: "/passages"))
  end

  def test_request_fields_never_match_a_job_even_negated
    refute build("http.method", "in", ["GET"]).match?(job)
    refute build("url.path", "prefix", "/a", negate: true).match?(job)
    refute build_query("present", "page", negate: true).match?(job)
    refute build("http.status_code", "between", [500, 599], negate: true).match?(job)
  end

  private

  def build(field, op, value, negate: false)
    Flare::TraceFilter.build({ "field" => field, "op" => op, "value" => value, "negate" => negate }).tap do |filter|
      assert filter, "expected #{field} #{op} to build"
    end
  end

  def build_query(op, name, value = nil, negate: false)
    raw = { "field" => "url.query_param", "op" => op, "name" => name, "negate" => negate }
    raw["value"] = value if value
    Flare::TraceFilter.build(raw).tap { |filter| assert filter }
  end

  def web(method: "GET", path: "/passages", query: nil, status: 200, duration_ms: 50, attributes: nil)
    attributes ||= {
      "http.method" => method,
      "url.path" => path,
      "url.query" => query,
      "http.status_code" => status
    }.compact
    Span.new(kind: :server, attributes: attributes, **timestamps(duration_ms))
  end

  def job(duration_ms: 50)
    Span.new(kind: :consumer, attributes: { "code.namespace" => "ImportFeed" }, **timestamps(duration_ms))
  end

  def timestamps(duration_ms)
    { start_timestamp: 1_000_000_000, end_timestamp: 1_000_000_000 + (duration_ms * 1_000_000) }
  end
end
