# frozen_string_literal: true

require_relative "test_helper"
require "flare/metric_storage"
require "flare/metric_span_processor"

class MetricSpanProcessorTest < Minitest::Test
  def setup
    @storage = Flare::MetricStorage.new
    @http_config = Flare::HttpMetricsConfig.new
    @processor = Flare::MetricSpanProcessor.new(storage: @storage, http_metrics_config: @http_config)
  end

  def test_web_request_creates_metric
    span = MockSpan.new(
      kind: :server,
      parent_span_id: nil,
      attributes: {
        "http.status_code" => 200,
        "code.namespace" => "UsersController",
        "code.function" => "show"
      },
      start_ns: 0,
      end_ns: 100_000_000 # 100ms
    )

    @processor.on_end(span)

    assert_equal 1, @storage.size
    key = @storage.drain.keys.first
    assert_equal "web", key.namespace
    assert_equal "rails", key.service
    assert_equal "UsersController#show", key.target
    assert_equal "2xx", key.operation
  end

  def test_web_request_error_tracking
    span = MockSpan.new(
      kind: :server,
      parent_span_id: nil,
      attributes: {
        "http.status_code" => 500,
        "code.namespace" => "UsersController",
        "code.function" => "show"
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    @processor.on_end(span)

    result = @storage.drain
    counter = result.values.first
    assert_equal 1, counter[:error_count]
  end

  def test_web_request_with_transaction_name_uses_it
    span = MockSpan.new(
      kind: :server,
      parent_span_id: nil,
      attributes: {
        "http.status_code" => 200,
        Flare::TRANSACTION_NAME_ATTRIBUTE => "RestApi::Routes::Audits#get"
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    @processor.on_end(span)

    assert_equal 1, @storage.size
    key = @storage.drain.keys.first
    assert_equal "web", key.namespace
    assert_equal "rails", key.service
    assert_equal "RestApi::Routes::Audits#get", key.target
    assert_equal "2xx", key.operation
  end

  def test_web_request_transaction_name_overrides_controller
    span = MockSpan.new(
      kind: :server,
      parent_span_id: nil,
      attributes: {
        "http.status_code" => 200,
        "code.namespace" => "UsersController",
        "code.function" => "show",
        Flare::TRANSACTION_NAME_ATTRIBUTE => "CustomName#action"
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "CustomName#action", key.target
  end

  def test_skips_web_requests_without_controller
    # Requests that don't hit a Rails controller (assets, favicon, bot probes)
    # should not be tracked as web metrics
    span = MockSpan.new(
      kind: :server,
      parent_span_id: nil,
      attributes: {
        "http.status_code" => 404,
        "http.target" => "/favicon.ico",
        "http.method" => "GET"
      },
      start_ns: 0,
      end_ns: 1_000_000
    )

    @processor.on_end(span)

    assert @storage.empty?
  end

  def test_background_job_with_transaction_name_uses_it
    span = MockSpan.new(
      kind: :consumer,
      parent_span_id: nil,
      name: "MyJob process",
      attributes: {
        "messaging.system" => "sidekiq",
        Flare::TRANSACTION_NAME_ATTRIBUTE => "CustomWorker"
      },
      start_ns: 0,
      end_ns: 50_000_000
    )

    @processor.on_end(span)

    assert_equal 1, @storage.size
    key = @storage.drain.keys.first
    assert_equal "job", key.namespace
    assert_equal "CustomWorker", key.target
    assert_equal "perform", key.operation
  end

  def test_background_job_creates_metric
    span = MockSpan.new(
      kind: :consumer,
      parent_span_id: nil,
      name: "MyJob process",
      attributes: {
        "code.namespace" => "MyJob",
        "code.function" => "perform",
        "messaging.system" => "sidekiq"
      },
      start_ns: 0,
      end_ns: 50_000_000 # 50ms
    )

    @processor.on_end(span)

    assert_equal 1, @storage.size
    key = @storage.drain.keys.first
    assert_equal "job", key.namespace
    assert_equal "sidekiq", key.service
    assert_equal "MyJob", key.target
    assert_equal "perform", key.operation
  end

  def test_database_span_creates_metric
    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "db.system" => "postgresql",
        "db.name" => "myapp_production",
        "db.sql.table" => "users",
        "db.operation" => "SELECT"
      },
      start_ns: 0,
      end_ns: 5_000_000 # 5ms
    )

    @processor.on_end(span)

    assert_equal 1, @storage.size
    key = @storage.drain.keys.first
    assert_equal "db", key.namespace
    assert_equal "postgresql", key.service
    assert_equal "users", key.target
    assert_equal "SELECT", key.operation
  end

  def test_redis_span_creates_metric
    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "db.system" => "redis",
        "db.redis.database_index" => "0",
        "db.operation" => "GET"
      },
      start_ns: 0,
      end_ns: 1_000_000 # 1ms
    )

    @processor.on_end(span)

    assert_equal 1, @storage.size
    key = @storage.drain.keys.first
    assert_equal "db", key.namespace
    assert_equal "redis", key.service
    assert_equal "0", key.target
    assert_equal "get", key.operation
  end

  def test_http_client_span_creates_metric
    @http_config.host("api.stripe.com", :all)

    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "POST",
        "http.host" => "api.stripe.com",
        "http.target" => "/v1/charges",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 200_000_000 # 200ms
    )

    @processor.on_end(span)

    assert_equal 1, @storage.size
    key = @storage.drain.keys.first
    assert_equal "http", key.namespace
    assert_equal "api.stripe.com", key.service
    assert_equal "POST /v1/charges", key.target
    assert_equal "2xx", key.operation
  end

  def test_duration_calculation
    span = MockSpan.new(
      kind: :server,
      parent_span_id: nil,
      attributes: {
        "http.status_code" => 200,
        "code.namespace" => "UsersController",
        "code.function" => "index"
      },
      start_ns: 1_000_000_000, # 1 second mark
      end_ns: 1_150_000_000 # 1.15 second mark = 150ms duration
    )

    @processor.on_end(span)

    result = @storage.drain
    counter = result.values.first
    assert_equal 150, counter[:sum_ms]
  end

  def test_server_span_with_remote_parent_creates_web_metric
    # Server spans may have a remote parent from distributed trace propagation
    # (e.g., traceparent header). They still represent the web request handled
    # by this application and should be tracked.
    span = MockSpan.new(
      kind: :server,
      parent_span_id: "abc123def456",
      attributes: {
        "http.status_code" => 200,
        "code.namespace" => "OrdersController",
        "code.function" => "create"
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    @processor.on_end(span)

    assert_equal 1, @storage.size
    key = @storage.drain.keys.first
    assert_equal "web", key.namespace
    assert_equal "rails", key.service
    assert_equal "OrdersController#create", key.target
    assert_equal "2xx", key.operation
  end

  def test_ignores_spans_without_timestamps
    span = MockSpan.new(
      kind: :server,
      parent_span_id: nil,
      attributes: {},
      start_ns: nil,
      end_ns: nil
    )

    @processor.on_end(span)

    assert @storage.empty?
  end

  def test_force_flush_returns_success
    result = @processor.force_flush
    assert_equal OpenTelemetry::SDK::Trace::Export::SUCCESS, result
  end

  def test_shutdown_returns_success
    result = @processor.shutdown
    assert_equal OpenTelemetry::SDK::Trace::Export::SUCCESS, result
  end

  def test_http_path_normalizes_numeric_ids
    @http_config.host("api.example.com", :all)

    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "GET",
        "http.host" => "api.example.com",
        "http.target" => "/users/12345/posts/67890",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "GET /users/:id/posts/:id", key.target
  end

  def test_http_path_normalizes_uuids
    @http_config.host("api.example.com", :all)

    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "GET",
        "http.host" => "api.example.com",
        "http.target" => "/items/550e8400-e29b-41d4-a716-446655440000",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "GET /items/:uuid", key.target
  end

  def test_http_path_normalizes_mongo_ids
    @http_config.host("api.example.com", :all)

    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "GET",
        "http.host" => "api.example.com",
        "http.target" => "/documents/507f1f77bcf86cd799439011",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "GET /documents/:id", key.target
  end

  def test_http_path_normalizes_long_tokens
    @http_config.host("api.example.com", :all)

    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "GET",
        "http.host" => "api.example.com",
        "http.target" => "/verify/a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "GET /verify/:token", key.target
  end

  def test_http_path_preserves_static_segments
    @http_config.host("api.example.com", :all)

    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "GET",
        "http.host" => "api.example.com",
        "http.target" => "/api/v1/users/search",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "GET /api/v1/users/search", key.target
  end

  # Cache metric tests

  def test_cache_read_hit_creates_metric
    span = MockSpan.new(
      kind: :internal,
      parent_span_id: "abc123",
      name: "cache_read.active_support",
      attributes: {
        "key" => "user:12345:stats",
        "hit" => true,
        "store" => "ActiveSupport::Cache::RedisCacheStore"
      },
      start_ns: 0,
      end_ns: 2_000_000
    )

    @processor.on_end(span)

    assert_equal 1, @storage.size
    key = @storage.drain.keys.first
    assert_equal "cache", key.namespace
    assert_equal "redis", key.service
    assert_equal "read.hit", key.target
    assert_equal "read.hit", key.operation
  end

  def test_cache_read_miss_creates_metric
    span = MockSpan.new(
      kind: :internal,
      parent_span_id: "abc123",
      name: "cache_read.active_support",
      attributes: {
        "key" => "user:12345:stats",
        "hit" => false,
        "store" => "ActiveSupport::Cache::RedisCacheStore"
      },
      start_ns: 0,
      end_ns: 2_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "cache", key.namespace
    assert_equal "read.miss", key.operation
  end

  def test_cache_write_creates_metric
    span = MockSpan.new(
      kind: :internal,
      parent_span_id: "abc123",
      name: "cache_write.active_support",
      attributes: {
        "key" => "session:abc123",
        "store" => "ActiveSupport::Cache::MemCacheStore"
      },
      start_ns: 0,
      end_ns: 3_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "cache", key.namespace
    assert_equal "memcache", key.service
    assert_equal "write", key.target
    assert_equal "write", key.operation
  end

  def test_cache_delete_creates_metric
    span = MockSpan.new(
      kind: :internal,
      parent_span_id: "abc123",
      name: "cache_delete.active_support",
      attributes: {
        "key" => "fragment/users/list",
        "store" => "ActiveSupport::Cache::FileStore"
      },
      start_ns: 0,
      end_ns: 1_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "cache", key.namespace
    assert_equal "file", key.service
    assert_equal "delete", key.target
    assert_equal "delete", key.operation
  end

  def test_cache_exist_hit_creates_metric
    span = MockSpan.new(
      kind: :internal,
      parent_span_id: "abc123",
      name: "cache_exist?.active_support",
      attributes: {
        "key" => "lock:job:42",
        "exist" => true,
        "store" => "ActiveSupport::Cache::MemoryStore"
      },
      start_ns: 0,
      end_ns: 500_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "cache", key.namespace
    assert_equal "memory", key.service
    assert_equal "exist.hit", key.target
    assert_equal "exist.hit", key.operation
  end

  def test_cache_exist_miss_creates_metric
    span = MockSpan.new(
      kind: :internal,
      parent_span_id: "abc123",
      name: "cache_exist?.active_support",
      attributes: {
        "key" => "lock:job:99",
        "exist" => false,
        "store" => "ActiveSupport::Cache::MemoryStore"
      },
      start_ns: 0,
      end_ns: 500_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "exist.miss", key.operation
  end

  def test_cache_fetch_hit_creates_metric
    span = MockSpan.new(
      kind: :internal,
      parent_span_id: "abc123",
      name: "cache_fetch_hit.active_support",
      attributes: {
        "key" => "api:response:latest",
        "store" => "ActiveSupport::Cache::RedisCacheStore"
      },
      start_ns: 0,
      end_ns: 1_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "cache", key.namespace
    assert_equal "redis", key.service
    assert_equal "fetch_hit", key.target
    assert_equal "fetch_hit", key.operation
  end

  def test_cache_unknown_store_fallback
    span = MockSpan.new(
      kind: :internal,
      parent_span_id: "abc123",
      name: "cache_read.active_support",
      attributes: {
        "key" => "test:key",
        "hit" => true,
        "store" => "MyApp::CustomCacheStore"
      },
      start_ns: 0,
      end_ns: 1_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "custom", key.service
  end

  def test_cache_missing_store_uses_unknown
    span = MockSpan.new(
      kind: :internal,
      parent_span_id: "abc123",
      name: "cache_write.active_support",
      attributes: { "key" => "test:key" },
      start_ns: 0,
      end_ns: 1_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "unknown", key.service
  end

  # View metric tests

  def test_view_template_creates_metric
    span = MockSpan.new(
      kind: :internal,
      parent_span_id: "abc123",
      name: "render_template.action_view",
      attributes: {
        "identifier" => "/Users/john/myapp/app/views/users/show.html.erb"
      },
      start_ns: 0,
      end_ns: 10_000_000
    )

    @processor.on_end(span)

    assert_equal 1, @storage.size
    key = @storage.drain.keys.first
    assert_equal "view", key.namespace
    assert_equal "actionview", key.service
    assert_equal "users/show.html.erb", key.target
    assert_equal "template", key.operation
  end

  def test_view_partial_creates_metric
    span = MockSpan.new(
      kind: :internal,
      parent_span_id: "abc123",
      name: "render_partial.action_view",
      attributes: {
        "identifier" => "/Users/john/myapp/app/views/shared/_header.html.erb"
      },
      start_ns: 0,
      end_ns: 5_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "view", key.namespace
    assert_equal "shared/_header.html.erb", key.target
    assert_equal "partial", key.operation
  end

  def test_view_layout_creates_metric
    span = MockSpan.new(
      kind: :internal,
      parent_span_id: "abc123",
      name: "render_layout.action_view",
      attributes: {
        "identifier" => "/Users/john/myapp/app/views/layouts/application.html.erb"
      },
      start_ns: 0,
      end_ns: 15_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "view", key.namespace
    assert_equal "layouts/application.html.erb", key.target
    assert_equal "layout", key.operation
  end

  def test_view_collection_creates_metric
    span = MockSpan.new(
      kind: :internal,
      parent_span_id: "abc123",
      name: "render_collection.action_view",
      attributes: {
        "identifier" => "/Users/john/myapp/app/views/posts/_post.html.erb"
      },
      start_ns: 0,
      end_ns: 20_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "view", key.namespace
    assert_equal "posts/_post.html.erb", key.target
    assert_equal "collection", key.operation
  end

  def test_view_missing_identifier_uses_unknown
    span = MockSpan.new(
      kind: :internal,
      parent_span_id: "abc123",
      name: "render_template.action_view",
      attributes: {},
      start_ns: 0,
      end_ns: 5_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "view", key.namespace
    assert_equal "unknown", key.target
  end

  def test_view_identifier_without_app_views_uses_basename
    span = MockSpan.new(
      kind: :internal,
      parent_span_id: "abc123",
      name: "render_template.action_view",
      attributes: {
        "identifier" => "inline template"
      },
      start_ns: 0,
      end_ns: 1_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "inline template", key.target
  end

  def test_database_span_extracts_table_from_sql_when_db_sql_table_missing
    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "db.system" => "mysql",
        "db.name" => "primary",
        "db.statement" => "SELECT `users`.* FROM `users` WHERE `users`.`id` = 1",
        "db.operation" => "SELECT"
      },
      start_ns: 0,
      end_ns: 5_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "db", key.namespace
    assert_equal "users", key.target
  end

  def test_database_span_falls_back_to_db_name_when_no_sql
    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "db.system" => "mysql",
        "db.name" => "primary",
        "db.operation" => "SELECT"
      },
      start_ns: 0,
      end_ns: 5_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "primary", key.target
  end

  def test_database_span_extracts_table_from_insert_sql
    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "db.system" => "mysql",
        "db.name" => "primary",
        "db.statement" => "INSERT INTO `orders` (`user_id`, `total`) VALUES (1, 99.99)",
        "db.operation" => "INSERT"
      },
      start_ns: 0,
      end_ns: 5_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "orders", key.target
  end

  def test_database_span_extracts_table_from_update_sql
    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "db.system" => "mysql",
        "db.name" => "cache",
        "db.statement" => "UPDATE `sessions` SET `updated_at` = NOW() WHERE `id` = 5",
        "db.operation" => "UPDATE"
      },
      start_ns: 0,
      end_ns: 5_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "sessions", key.target
  end

  # HTTP metrics config tests

  def test_http_unconfigured_host_uses_star
    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "GET",
        "http.host" => "unknown-api.example.com",
        "http.target" => "/v1/users/123",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "GET *", key.target
  end

  def test_http_allow_matches_path
    @http_config.host "api.stripe.com" do |h|
      h.allow %r{/v1/charges}
    end

    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "POST",
        "http.host" => "api.stripe.com",
        "http.target" => "/v1/charges/12345",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "POST /v1/charges/:id", key.target
  end

  def test_http_allow_unmatched_path_uses_star
    @http_config.host "api.stripe.com" do |h|
      h.allow %r{/v1/charges}
    end

    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "GET",
        "http.host" => "api.stripe.com",
        "http.target" => "/v1/customers/cus_abc123",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "GET *", key.target
  end

  def test_http_map_uses_custom_replacement
    @http_config.host "api.example.com" do |h|
      h.map %r{/v1/connect/[\w-]+/transfers}, "/v1/connect/:account/transfers"
    end

    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "POST",
        "http.host" => "api.example.com",
        "http.target" => "/v1/connect/acct_abc123/transfers",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "POST /v1/connect/:account/transfers", key.target
  end

  def test_http_allow_first_match_wins
    @http_config.host "api.example.com" do |h|
      h.map %r{/v1/users}, "/v1/users-custom"
      h.allow %r{/v1/users}
    end

    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "GET",
        "http.host" => "api.example.com",
        "http.target" => "/v1/users/123",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "GET /v1/users-custom", key.target
  end

  def test_http_default_config_allows_flare_dev
    config = Flare::HttpMetricsConfig::DEFAULT
    processor = Flare::MetricSpanProcessor.new(storage: @storage, http_metrics_config: config)

    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "POST",
        "http.host" => "flare.am",
        "http.target" => "/api/metrics",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "POST /api/metrics", key.target
  end

  def test_http_default_config_allows_flippercloud_adapter
    config = Flare::HttpMetricsConfig::DEFAULT
    processor = Flare::MetricSpanProcessor.new(storage: @storage, http_metrics_config: config)

    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "GET",
        "http.host" => "www.flippercloud.io",
        "http.target" => "/adapter/features",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "GET /adapter/features", key.target
  end

  def test_http_default_config_normalizes_flippercloud_feature_name
    config = Flare::HttpMetricsConfig::DEFAULT
    processor = Flare::MetricSpanProcessor.new(storage: @storage, http_metrics_config: config)

    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "GET",
        "http.host" => "www.flippercloud.io",
        "http.target" => "/adapter/features/my_feature_flag",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "GET /adapter/features/:name", key.target
  end

  def test_http_default_config_normalizes_flippercloud_gate
    config = Flare::HttpMetricsConfig::DEFAULT
    processor = Flare::MetricSpanProcessor.new(storage: @storage, http_metrics_config: config)

    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "POST",
        "http.host" => "www.flippercloud.io",
        "http.target" => "/adapter/features/my_feature/boolean",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "POST /adapter/features/:name/:gate", key.target
  end

  def test_http_default_config_stars_unknown_host
    config = Flare::HttpMetricsConfig::DEFAULT
    processor = Flare::MetricSpanProcessor.new(storage: @storage, http_metrics_config: config)

    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "GET",
        "http.host" => "random-api.example.com",
        "http.target" => "/some/path",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "GET *", key.target
  end

  # Mock span class for testing
  class MockSpan
    attr_reader :kind, :parent_span_id, :name, :attributes, :start_timestamp, :end_timestamp, :status

    def initialize(kind:, parent_span_id:, attributes: {}, start_ns: 0, end_ns: 100_000_000, name: "test_span", status: nil)
      @kind = kind
      @parent_span_id = parent_span_id
      @name = name
      @attributes = attributes
      @start_timestamp = start_ns
      @end_timestamp = end_ns
      @status = status
    end
  end
end
