# Caboose

Track what just happened in your Rails app.

A Laravel Telescope-style debugging dashboard for Rails. Development-focused, local-first, captures everything happening in your app and displays it with a waterfall visualization.

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

Add Caboose to your Gemfile:

```ruby
gem "caboose"
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
caboose setup
```

The setup command will:

1. Authenticate with caboose.dev to configure metrics
2. Create a config initializer with sensible defaults
3. Update .gitignore

Start your Rails server and visit `/caboose` to see the dashboard.

### Manual Configuration

If you prefer to skip the setup wizard, just add the gem and visit `/caboose` in development. The dashboard works out of the box with no configuration needed.

To enable metrics, set `CABOOSE_KEY` in your environment (get one at [caboose.dev](https://caboose.dev)).

### CLI Commands

```bash
caboose setup    # Authenticate and configure Caboose
caboose doctor   # Check your setup for issues
caboose status   # Show current configuration
```

## Configuration

All configuration is optional. Caboose works out of the box with sensible defaults.

```ruby
Caboose.configure do |config|
  # Enable or disable Caboose (default: true)
  config.enabled = true

  # How long to keep spans in hours (default: 24)
  config.retention_hours = 24

  # Maximum number of spans to store (default: 10000)
  config.max_spans = 10_000

  # Path to the SQLite database (default: db/caboose.sqlite3)
  config.database_path = Rails.root.join("db", "caboose.sqlite3").to_s

  # Ignore specific requests (receives a Rack::Request, return true to ignore)
  config.ignore_request = ->(request) {
    request.path.start_with?("/health")
  }

  # Subscribe to custom notification prefixes (default: ["app."])
  config.subscribe_patterns << "mycompany."
end
```

## Custom Instrumentation

Caboose automatically captures Rails internals, but you can also instrument your own code. Use `ActiveSupport::Notifications.instrument` with an `app.` prefix:

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

This works in all environments - in production it's essentially a no-op, in development Caboose automatically captures and displays it.

### Custom Notification Prefixes

By default, Caboose subscribes to notifications starting with `app.`. You can add additional prefixes:

```ruby
Caboose.configure do |config|
  config.subscribe_patterns << "mycompany."
  config.subscribe_patterns << "external_service."
end
```

## How It Works

Caboose uses [OpenTelemetry](https://opentelemetry.io/) for instrumentation. It automatically configures:

- `OpenTelemetry::Instrumentation::Rack` - HTTP requests
- `OpenTelemetry::Instrumentation::ActiveSupport` - Notifications (SQL, cache, mail)
- `OpenTelemetry::Instrumentation::ActionPack` - Controller actions
- `OpenTelemetry::Instrumentation::ActionView` - View rendering
- `OpenTelemetry::Instrumentation::ActiveJob` - Background jobs
- `OpenTelemetry::Instrumentation::Net::HTTP` - Outgoing HTTP calls

Spans are stored in a local SQLite database (`db/caboose.sqlite3` by default) and automatically pruned based on retention settings.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/jnunemaker/caboose.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
