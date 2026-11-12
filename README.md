# Flare — App Monitoring

Light up what's slowing you down. [flare.am](https://flare.am)

App monitoring for Rails. Captures requests, queries, jobs, cache, views, HTTP calls, mail, and exceptions in development with a waterfall visualization dashboard. Sends lightweight aggregated metrics in production.

## Features

- **HTTP Requests** - Track all incoming requests with status codes, durations, and controller actions
- **Background Jobs** - Monitor ActiveJob processing with queue names and execution times
- **Database Queries** - See all SQL queries with the source location that triggered them
- **Cache Operations** - Track cache reads, writes, hits, and misses
- **View Rendering** - Monitor template and partial rendering times
- **HTTP Client Calls** - See outgoing HTTP requests to external services
- **Email Delivery** - Track ActionMailer sends with recipients and subjects
- **Exceptions** - View errors with full stacktraces

Each span shows a waterfall visualization of child operations, making it easy to understand request timing and identify bottlenecks.

## Installation

Add Flare to your Gemfile:

```ruby
gem "flare"
```

The local development dashboard uses SQLite to store spans. If your app doesn't already have `sqlite3` in its Gemfile, add it to the development group:

```ruby
group :development do
  gem "sqlite3"
end
```

Then run:

```bash
bundle install
flare setup
```

The setup command will:

1. Authenticate with flare.am to configure metrics
2. Create a config initializer with sensible defaults
3. Update .gitignore

Start your Rails server and visit `/flare` to see the dashboard.

### Manual Configuration

If you prefer to skip the setup wizard, just add the gem and visit `/flare` in development. The dashboard works out of the box with no configuration needed.

To enable metrics, set `FLARE_KEY` in your environment (get one at [flare.am](https://flare.am)).

### CLI Commands

```bash
flare setup    # Authenticate and configure Flare
flare doctor   # Check your setup for issues
flare status   # Show current configuration
flare requests # List recent requests from local development spans
flare request  # Show one request's timeline from local development spans
flare nplus1   # Find queries repeated within recent requests from local development spans
```

`flare requests` reads the local spans database, so you or a coding agent can make a request and check its duration and query count without opening `/flare`:

```bash
$ bundle exec flare requests --last 2
2026-10-27T20:14:03.412-04:00  GET     200       48.2ms    12 queries  /posts  PostsController#index  4bf92f3577b34da6a3ce929d0e0e4736
2026-10-27T20:13:41.087-04:00  GET     404        3.0ms     1 queries  /posts/9  PostsController#show  0af7651916cd43dd8448eb211c80319c
```

`flare request <trace_id>` shows what one of those requests did, in order, with the code that ran each query:

```bash
$ bundle exec flare request 4bf92f3577b34da6a3ce929d0e0e4736
GET /posts  200  48.2ms  PostsController#index
Started 2026-10-27T20:14:03.412-04:00  12 queries

   offset  duration
    1.2ms     0.4ms  sql.active_record: SELECT "posts".* FROM "posts"  app/controllers/posts_controller.rb:5
    2.1ms     0.2ms  sql.active_record: SELECT "users".* FROM "users" WHERE "users"."id" = ?  app/views/posts/index.html.erb:3
```

`flare nplus1` checks recent requests for the same query running more than once, ignoring the values bound to it, and names the code that ran it. Add `--last N` to check more or fewer requests than the default 10:

```bash
$ bundle exec flare nplus1
GET /posts  200  48.2ms  PostsController#index  4bf92f3577b34da6a3ce929d0e0e4736
  10x     2.3ms  SELECT "users".* FROM "users" WHERE "users"."id" = ?
     10x  app/views/posts/index.html.erb:3
```

All three commands take `--json` for machine-readable output and `--db PATH` if you changed `database_path`.

### Coding agents

Add something like this to your app's `AGENTS.md` or `CLAUDE.md` so coding agents (Claude Code, Codex, Cursor) use these commands:

```markdown
## Checking performance

Flare records every request in development. After changing a controller, view or query, make the request, then:

- `bundle exec flare requests --last 1 --json` shows its duration, query count and trace_id
- `bundle exec flare nplus1 --last 1 --json` shows any query it ran more than once, with the code that ran it
- `bundle exec flare request <trace_id> --json` shows every query in order, when you need the full timeline
```

No Flare account or network access needed.

## Configuration

All configuration is optional. Flare works out of the box with sensible defaults.

```ruby
Flare.configure do |config|
  # Enable or disable Flare (default: true)
  config.enabled = true

  # How long to keep spans in hours (default: 24)
  config.retention_hours = 24

  # Maximum number of spans to store (default: 10000)
  config.max_spans = 10_000

  # Path to the SQLite database (default: db/flare.sqlite3)
  config.database_path = Rails.root.join("db", "flare.sqlite3").to_s

  # Ignore specific requests (receives a Rack::Request, return true to ignore)
  config.ignore_request = ->(request) {
    request.path.start_with?("/health")
  }

  # Exceptions that don't count as errors in metrics (see below)
  config.ignore_errors << "MyApp::RetryLaterError"

  # Subscribe to custom notification prefixes (default: ["app."])
  config.subscribe_patterns << "mycompany."

  # The deployed revision, shown as deploy markers on your charts
  # (default: FLARE_REVISION, then your platform's commit variable, a
  # REVISION file, or git rev-parse HEAD)
  config.revision = ENV["MY_BUILD_SHA"]
end
```

### Errors that aren't failures

Some exceptions are control flow. A GoodJob job with `perform_limit` or `perform_throttle` raises `GoodJob::ActiveJobExtensions::Concurrency::ConcurrencyExceededError` (or its subclass `ThrottleExceededError`) to wait its turn, then retries. Flare counts a span that ends with an exception in `config.ignore_errors`, or a subclass of one, as a success: it still counts toward throughput and duration, just not the error rate. Traces still record the exception. Append your own class names, or assign a new list to replace the default:

```ruby
config.ignore_errors << "MyApp::RetryLaterError"
config.ignore_errors = []  # count every exception as an error
```

## Custom Instrumentation

Flare automatically captures Rails internals, but you can also instrument your own code. Use `ActiveSupport::Notifications.instrument` with an `app.` prefix:

```ruby
# In your application code
ActiveSupport::Notifications.instrument("app.geocoding", address: address) do
  geocoder.lookup(address)
end

ActiveSupport::Notifications.instrument("app.stripe.charge", amount: 1000) do
  Stripe::Charge.create(amount: 1000, currency: "usd")
end

ActiveSupport::Notifications.instrument("app.send_sms", to: phone) do
  twilio.messages.create(to: phone, body: message)
end
```

This works in all environments - in production it's essentially a no-op, in development Flare automatically captures and displays it.

### Custom Notification Prefixes

By default, Flare subscribes to notifications starting with `app.`. You can add additional prefixes:

```ruby
Flare.configure do |config|
  config.subscribe_patterns << "mycompany."
  config.subscribe_patterns << "external_service."
end
```

## How It Works

Flare uses [OpenTelemetry](https://opentelemetry.io/) for instrumentation. It automatically configures:

- `OpenTelemetry::Instrumentation::Rack` - HTTP requests
- `OpenTelemetry::Instrumentation::ActiveSupport` - Notifications (SQL, cache, mail)
- `OpenTelemetry::Instrumentation::ActionPack` - Controller actions
- `OpenTelemetry::Instrumentation::ActionView` - View rendering
- `OpenTelemetry::Instrumentation::ActiveJob` - Background jobs
- `OpenTelemetry::Instrumentation::Net::HTTP` - Outgoing HTTP calls

Spans are stored in a local SQLite database (`db/flare.sqlite3` by default) and automatically pruned based on retention settings.

### What leaves your app

Captured traces go through your app's `config.filter_parameters` before upload, including query strings, along with a default list of common credential names. SQL statements have their values replaced with `?`, Redis statements keep the command and the key's first segment, MongoDB commands keep their structure with values masked, URLs lose their userinfo and fragments, and mail recipients, subjects, job arguments and exception contents are left out. Cache keys keep only their leading word. Metrics carry names (controller, job, table, operation, host), not values, plus your app's deployed revision (usually a git SHA) so Flare can mark deploys. Your local development database and dashboard keep the full values, except Redis arguments, which aren't kept anywhere.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/verygoodsoftwarellc/flare-gem.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
