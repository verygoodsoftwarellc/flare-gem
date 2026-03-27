# Flare Demo App

A single-file Rails app for testing Flare.

## Running the demo

From the repository root:

```bash
bundle install
bundle exec ruby examples/app.rb
```

Or specify a custom port:

```bash
PORT=4000 bundle exec ruby examples/app.rb
```

Then visit:
- http://localhost:9999 - Demo app home page
- http://localhost:9999/flare - Flare dashboard

## Endpoints

| Path | Description |
|------|-------------|
| `/` | Home page |
| `/api` | Simulates SQL query, cache read, and view render |
| `/slow` | 500ms slow endpoint |
| `/error` | Raises an exception (for testing error tracking) |
| `/flare` | Flare dashboard |

Click around, then check the Flare dashboard to see the recorded cases and clues.
