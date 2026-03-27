# Flare

Rails debugging/observability gem. Tracks requests, queries, jobs, cache, views, and more using OpenTelemetry.

## Architecture

Two pieces:

- **flare** (this repo) - Ruby gem installed in the user's Rails app. Instruments via OpenTelemetry, stores spans in local SQLite, flushes aggregated metrics to flare-web.
- **flare-web** - Hosted Rails app at flare.am. Receives metrics, manages projects/auth, provides the CLI auth flow.

## Environment Behavior

The gem behaves differently per environment:

| | Development | Production | Test |
|---|---|---|---|
| **Spans** (local SQLite) | ON | OFF | OFF |
| **Metrics** (aggregated, sent to flare-web) | ON | ON | OFF |
| **Dashboard UI** (`/flare`) | auto-mounted | not mounted | auto-mounted |

### Spans (Development only)

Spans are detailed trace data (every SQL query, cache hit, view render, etc.) stored in a local SQLite database at `db/flare.sqlite3`. The `SQLiteExporter` writes spans via the OTel `BatchSpanProcessor`. Spans are auto-pruned based on `retention_hours` (default: 24h) and `max_spans` (default: 10,000). This is too expensive for production.

The dashboard at `/flare` reads from this SQLite database to show requests, jobs, queries, cache, views, HTTP calls, mail, and exceptions with waterfall visualizations.

### Metrics (All environments except test)

Metrics are lightweight aggregated counters computed from spans in-memory. The `MetricSpanProcessor` (an OTel span processor) extracts metrics from every span as it finishes, bucketed by minute into a `MetricStorage` (thread-safe `Concurrent::Map`). Categories:

- **web** - HTTP requests (namespace=web, service=rails, target=controller, operation=method)
- **background** - Jobs (namespace=background, service=activejob/sidekiq, target=job class, operation=action)
- **db** - Database queries (namespace=db, service=sqlite/postgresql/etc, target=table, operation=SELECT/INSERT/etc)
- **http** - Outgoing HTTP calls (namespace=http, service=host, target=VERB+path, operation=status class). Paths default to `*` to prevent cardinality explosion; see HTTP Metrics Path Config below.

The `MetricFlusher` drains the storage every 60s and the `MetricSubmitter` posts gzipped JSON to `POST {url}/api/metrics` with `Authorization: Bearer {FLARE_KEY}`. Only runs if both `url` and `key` are configured.

### Fork Safety

The gem detects forking (Puma workers, Passenger, etc.) inline on every span end. When `$$` changes, it calls `Flare.after_fork` which restarts the `MetricFlusher` timer thread. Same pattern as Flipper.

## Setup Flow (CLI + flare-web)

Users run `bundle exec flare setup` from their Rails app root. The command does three things:

### 1. Authentication (OAuth-style flow with flare-web)

- Generates a PKCE code challenge (`state`, `code_verifier`, `code_challenge`)
- Starts a local TCP server on a random port (127.0.0.1)
- Opens the browser to `flare.am/cli/authorize?state=...&port=...&code_challenge=...`
- User logs in / authorizes on flare-web
- flare-web redirects back to the local TCP server at `/callback?state=...&code=...`
- CLI verifies state matches, then exchanges the auth code for a token via `POST flare.am/api/cli/exchange` (sending `code` + `code_verifier`)
- User chooses where to save the `FLARE_KEY` token: `.env` file, Rails credentials, or print to stdout

### 2. Create initializer

Writes `config/initializers/flare.rb` with commented config options (retention, max spans, database path, ignore patterns, subscribe patterns).

### 3. Update .gitignore

Adds `.env` and `/db/flare.sqlite3*` to `.gitignore` if not already present.

## Key Configuration

- `FLARE_KEY` - API key for metrics submission (set via env var or Rails credentials at `flare.key`)
- `FLARE_URL` - Metrics endpoint (defaults to `https://flare.am`, overridable via env var or credentials at `flare.url`)
- `FLARE_HOST` - Used only by the CLI for the auth flow (defaults to `https://flare.am`)
- `FLARE_DEBUG` - Set to `1` to enable debug logging

The engine loads `FLARE_KEY` from Rails credentials automatically if the env var isn't set (see `engine.rb` initializer `flare.defaults`).

### HTTP Metrics Path Config

Outgoing HTTP paths default to `VERB *` per host to prevent high-cardinality metric keys (e.g., slug-based URLs). Users opt-in to path detail per host via `HttpMetricsConfig` DSL with `allow` (use `normalize_path`) and `map` (custom replacement). First match wins. Built-in defaults cover `flare.am` and `www.flippercloud.io`. User config merges with defaults (never replaces).

```ruby
Flare.configure do |config|
  config.http_metrics do |http|
    http.host "api.stripe.com" do |h|
      h.allow %r{/v1/customers}       # tracked, auto-normalized
      h.allow %r{/v1/charges}
      h.map %r{/v1/connect/[\w-]+/transfers}, "/v1/connect/:account/transfers"  # custom normalization
    end
    http.host "api.github.com", :all   # track all paths, auto-normalized
  end
end
```

See `lib/flare/http_metrics_config.rb` for implementation.

## Engine Initialization Order

The `Flare::Engine` runs initializers in a specific order:

1. `flare.defaults` (before `load_config_initializers`) - loads `FLARE_KEY` from Rails credentials if not in ENV
2. `flare.static_assets` - serves `/flare-assets` from engine's `public/` directory
3. `flare.opentelemetry` (before `build_middleware_stack`) - configures OTel SDK and instrumentations so Rack/ActionPack middleware gets inserted
4. `flare.routes` (before `add_routing_paths`) - auto-mounts engine at `/flare` in development/test
5. `config.after_initialize` - starts the `MetricFlusher` (after user initializers have run so config is applied)

## OTel Instrumentations

Auto-configured instrumentations:
- `Rack` - HTTP requests (ignores `/flare` paths and user-configured ignore patterns)
- `Net::HTTP` - outgoing HTTP calls
- `ActiveSupport` - notifications (SQL, cache, mailer)
- `ActionPack` - controller actions (if ActionController is defined)
- `ActionView` - view rendering (if ActionView is defined)
- `ActiveJob` - background jobs (if ActiveJob is defined)

Additionally subscribes to specific `ActiveSupport::Notifications` patterns: `sql.active_record`, `instantiation.active_record`, `cache_*.active_support`, `deliver.action_mailer`, `process.action_mailer`, and any custom prefixes (default: `app.*`).

## Custom Instrumentation

Users instrument their code with `ActiveSupport::Notifications.instrument("app.whatever")` using the `app.` prefix. Works in all environments. In dev, Flare auto-subscribes and creates spans. In production, it's essentially a no-op unless the user adds custom subscribers.

## CLI

`exe/flare` - entry point. Commands: `setup`, `version`, `help`.

`--force` flag on setup re-runs auth even if `FLARE_KEY` exists in `.env`.

## Development

```
bundle install
rake test
```

Tests use Minitest. The test helper loads core library classes directly without Rails to keep unit tests fast. Use `RAILS_VERSION` env var to test against different Rails versions.

## File Structure

- `lib/flare.rb` - main module, OTel configuration, notification subscriptions
- `lib/flare/engine.rb` - Rails engine (routes, initializers, middleware)
- `lib/flare/configuration.rb` - all config options and environment defaults
- `lib/flare/cli.rb` - CLI command router
- `lib/flare/cli/setup_command.rb` - setup/auth flow
- `lib/flare/sqlite_exporter.rb` - OTel span exporter that writes to SQLite
- `lib/flare/http_metrics_config.rb` - per-host HTTP path allow/map DSL for metrics cardinality control
- `lib/flare/metric_span_processor.rb` - OTel span processor that extracts metrics
- `lib/flare/metric_storage.rb` - thread-safe in-memory metric aggregation
- `lib/flare/metric_flusher.rb` - background timer that drains and submits metrics
- `lib/flare/metric_submitter.rb` - HTTP client for posting metrics to flare-web
- `lib/flare/source_location.rb` - finds app code location that triggered a span
- `app/` - Rails engine controllers/views for the dashboard UI
- `config/routes.rb` - engine routes (requests, jobs, spans by category)
