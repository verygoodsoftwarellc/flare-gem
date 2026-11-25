# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "concurrent/executor/immediate_executor"
require "rails"
require "flare"

class ErrorTrackerTest < Minitest::Test
  class NotFoundError < StandardError; end
  class MissingThingError < NotFoundError; end

  class RecordingUploader
    attr_reader :uploads

    def initialize
      @uploads = []
    end

    def upload(sample, entry)
      @uploads << [sample, entry]
      true
    end
  end

  def setup
    @configuration = Flare::Configuration.new
    @configuration.revision = "abc123"
    @uploader = RecordingUploader.new
    @tracker = Flare::ErrorTracker.new(
      configuration: @configuration,
      uploader: @uploader,
      executor: Concurrent::ImmediateExecutor.new,
      logger: Logger.new(IO::NULL)
    )
  end

  def teardown
    Flare::ErrorTracker.current = nil
  end

  def test_gate_off_counts_and_holds_nothing
    refute @tracker.enabled?
    refute @tracker.report(raised, handled: false)

    storage = Flare::MetricStorage.new
    @tracker.record(storage)
    assert storage.empty?
    assert_empty @tracker.sample_request
  end

  def test_rules_response_turns_the_gate_on_and_off
    @tracker.apply_rules({ "error_tracking" => true })
    assert @tracker.enabled?

    @tracker.report(raised, handled: false)
    @tracker.apply_rules({ "trace_rules" => [] })
    refute @tracker.enabled?

    storage = Flare::MetricStorage.new
    @tracker.record(storage)
    assert storage.empty?, "turning off drops pending counts"
    assert_equal 0, @tracker.waiting_count
  end

  def test_counts_go_out_as_error_rows
    enable
    error = raised("boom 1")
    assert @tracker.report(error, handled: false, context: { operation: "UsersController#show" })
    @tracker.report(raised("boom 2"), handled: true, context: { operation: "UsersController#show" })

    rows = flush
    assert_equal 1, rows.size
    key, values = rows.first
    assert_equal "error", key.namespace
    assert_equal "RuntimeError", key.service
    assert_match(/\A[0-9a-f]{16}\z/, key.target)
    assert_equal "UsersController#show", key.operation
    assert_equal 2, values[:count]
    assert_equal 1, values[:error_count], "error_count is unhandled occurrences"
    assert_equal 0, values[:sum_ms]
  end

  def test_each_exception_counts_once
    enable
    error = raised
    assert @tracker.report(error, handled: true)
    refute @tracker.report(error, handled: false)

    assert_equal 1, flush.values.sum { |v| v[:count] }
  end

  def test_rails_subscriber_and_span_count_the_same_exception_once
    enable
    error = raised
    span = finished_span(error)

    # Web: the reporter sees it first, then the request span finishes.
    Flare::ErrorTracker::ReporterSubscriber.new(@tracker).report(error, handled: false, severity: :error, context: {}, source: "application.action_dispatch")
    @tracker.entry_span_finished(span, operation: "UsersController#show", error: true)
    assert_equal 1, flush.values.sum { |v| v[:count] }

    # Jobs: the span finishes first, then the reporter sees it.
    error = raised
    @tracker.entry_span_finished(finished_span(error), operation: "SyncJob", error: true)
    Flare::ErrorTracker::ReporterSubscriber.new(@tracker).report(error, handled: false, context: {})
    rows = flush
    assert_equal 1, rows.values.sum { |v| v[:count] }
    assert_equal "SyncJob", rows.keys.first.operation
  end

  def test_failed_span_without_a_known_exception_is_skipped
    enable
    span = Struct.new(:context, :events, :status).new(nil, [], nil)
    @tracker.entry_span_finished(span, operation: "X#y", error: true)
    assert_empty flush
  end

  def test_child_span_exception_counts_for_a_retried_job
    enable
    install_span_capture
    tracer = OpenTelemetry::SDK::Trace::TracerProvider.new.tracer("test")
    error = raised
    root = tracer.start_root_span("SyncJob process", kind: :consumer)
    OpenTelemetry::Trace.with_span(root) do
      tracer.in_span("SyncJob retry") { |child| child.record_exception(error) }
    end
    root.status = OpenTelemetry::Trace::Status.error("Unexpected ActiveJob Error RuntimeError")
    root.finish

    @tracker.entry_span_finished(root, operation: "SyncJob", error: true)
    assert_equal 1, flush.values.sum { |v| v[:count] }
  end

  def test_ignored_errors_and_subclasses_are_skipped
    enable
    @configuration.ignore_errors = [NotFoundError.name]
    refute @tracker.report(raised_with(MissingThingError), handled: false)

    @configuration.ignore_errors = []
    @configuration.error_tracking_ignores = [NotFoundError.name]
    refute @tracker.report(raised_with(NotFoundError), handled: false)
    assert @tracker.report(raised, handled: false)
  end

  def test_default_noise_is_ignored
    assert_includes Flare::Configuration::DEFAULT_ERROR_TRACKING_IGNORES, "ActionController::RoutingError"
    assert_includes Flare::Configuration::DEFAULT_ERROR_TRACKING_IGNORES, "ActiveRecord::RecordNotFound"
    assert_includes Flare::Configuration::DEFAULT_ERROR_TRACKING_IGNORES, "ActionController::InvalidAuthenticityToken"
    refute_includes Flare::Configuration::DEFAULT_IGNORE_ERRORS, "ActiveRecord::RecordNotFound"
  end

  def test_cache_store_sources_are_skipped
    enable
    refute @tracker.report(raised, handled: true, source: "redis_cache_store.active_support")
  end

  def test_service_is_truncated_to_100
    enable
    long = Class.new(StandardError)
    name = "A" * 150
    long.define_singleton_method(:name) { name }
    @tracker.report(raised_with(long), handled: false)

    assert_equal 100, flush.keys.first.service.length
  end

  # POST /api/metrics rejects the whole request when operation is over 100.
  def test_operation_is_truncated_to_100
    enable
    @tracker.report(raised, handled: false, context: { operation: "A" * 300 })

    assert_equal 100, flush.keys.first.operation.length
  end

  def test_at_most_100_fingerprints_per_flush
    enable
    150.times do |i|
      @tracker.report(error_at("app/models/m#{i}.rb", "go"), handled: false)
    end
    # One busy fingerprint must survive the cut.
    busy = error_at("app/models/busy.rb", "go")
    @tracker.report(busy, handled: false)
    5.times { @tracker.report(error_at("app/models/busy.rb", "go"), handled: false) }

    rows = flush
    fingerprints = rows.keys.map(&:target).uniq
    assert_equal 101, fingerprints.size, "100 kept plus the overflow fingerprint"
    overflow = rows.select { |k, _| k.target == Flare::ErrorTracker::OVERFLOW_FINGERPRINT }
    assert_equal 1, overflow.size
    assert_equal "overflow", overflow.keys.first.service
    assert_equal 156, rows.values.sum { |v| v[:count] }
    assert(rows.any? { |k, v| v[:count] == 6 && k.target != Flare::ErrorTracker::OVERFLOW_FINGERPRINT })
  end

  def test_holds_one_sample_per_new_fingerprint
    enable
    3.times { @tracker.report(raised, handled: false, context: { operation: "X#y" }) }

    assert_equal 1, @tracker.waiting_count
    fingerprint = @tracker.sample_request.first
    sample = JSON.parse(waiting(fingerprint)[:json])
    assert_equal fingerprint, sample["fingerprint"]
    assert_equal "X#y", sample["operation"]
    assert_equal "abc123", sample["revision"]
    assert_equal false, sample["handled"]
  end

  def test_caps_waiting_samples_and_requests
    enable
    25.times { |i| @tracker.report(error_at("app/models/m#{i}.rb", "go"), handled: false) }

    assert_equal 20, @tracker.waiting_count
    assert_equal 10, @tracker.sample_request.size
  end

  def test_granted_samples_upload_and_refused_are_dropped_for_good
    enable
    a = error_at("app/models/a.rb", "go")
    b = error_at("app/models/b.rb", "go")
    @tracker.report(a, handled: false)
    @tracker.report(b, handled: false)
    requested = @tracker.sample_request
    granted, refused = requested

    @tracker.apply_rules({
      "error_tracking" => true,
      "error_uploads" => [
        { "fingerprint" => granted, "upload_id" => "u1", "key" => "incoming/errors/env=1/fp=#{granted}/u1.json.gz",
          "put_url" => "https://r2/u1", "expires_at" => "2026-11-25T01:00:00Z" },
        { "fingerprint" => "0123456789abcdef", "upload_id" => "u2", "key" => "k", "put_url" => "https://r2/u2" }
      ]
    }, requested: requested)

    assert_equal 1, @uploader.uploads.size
    sample, entry = @uploader.uploads.first
    assert_equal granted, sample[:fingerprint]
    assert_equal "u1", entry[:upload_id]
    assert_equal 1, @tracker.refused_count.value
    assert_equal 0, @tracker.waiting_count
    assert_empty @tracker.sample_request

    # The same errors again don't hold new samples this process.
    @tracker.report(error_at("app/models/a.rb", "go"), handled: false)
    @tracker.report(error_at("app/models/b.rb", "go"), handled: false)
    assert_empty @tracker.sample_request
    refute_nil refused
  end

  def test_flare_report_is_handled_and_safe_without_a_tracker
    assert_nil Flare.report(raised)

    enable
    Flare::ErrorTracker.current = @tracker
    assert_nil Flare.report(raised, context: { operation: "Importer#run" })
    rows = flush
    assert_equal 1, rows.values.first[:count]
    assert_equal 0, rows.values.first[:error_count]
    assert_equal "Importer#run", rows.keys.first.operation
  end

  def test_report_never_raises
    enable
    bad = raised
    bad.define_singleton_method(:backtrace_locations) { raise "nope" }
    refute @tracker.report(bad, handled: false)
  end

  def test_invalid_utf8_operation_still_serializes
    enable
    @tracker.report(raised, handled: false, context: { operation: "Bad\xff#op".b })

    key, = flush.first
    assert_equal "Bad?#op", key.operation
    JSON.generate(key.operation)
  end

  def test_operation_in_another_encoding_is_transcoded
    enable
    @tracker.report(raised, handled: false, context: { operation: "Réserver".encode(Encoding::ISO_8859_1) })

    key, = flush.first
    assert_equal "Réserver", key.operation
  end

  def test_overflow_does_not_take_a_fingerprint_slot
    enable
    counts = @tracker.instance_variable_get(:@counts)
    bucket = Time.utc(2026, 11, 25, 12, 0)
    key = ->(fp) { Flare::MetricKey.new(bucket: bucket, namespace: "error", service: "E", target: fp, operation: "op") }
    100.times { |i| counts.add(key.call(format("%016x", i)), count: 2, sum_ms: 0) }
    counts.add(key.call(Flare::ErrorTracker::OVERFLOW_FINGERPRINT), count: 1_000, sum_ms: 0)

    rows = flush
    assert_equal 101, rows.size
    assert_equal 1_000, rows.sum { |k, v| k.target == Flare::ErrorTracker::OVERFLOW_FINGERPRINT ? v[:count] : 0 }
  end

  def test_bucket_is_the_utc_minute_on_non_utc_hosts
    clock = Object.new
    def clock.now = Time.new(2026, 11, 25, 16, 57, 30, "-05:00")
    tracker = Flare::ErrorTracker.new(configuration: @configuration, clock: clock, logger: Logger.new(IO::NULL))
    tracker.apply_rules({ "error_tracking" => true })
    tracker.report(raised, handled: false)

    storage = Flare::MetricStorage.new
    tracker.record(storage)
    key, = storage.drain.first
    assert_equal Time.utc(2026, 11, 25, 21, 57, 0), key.bucket
  end

  def test_distinct_rows_are_capped_between_flushes
    clock = Object.new
    def clock.now = Time.utc(2026, 11, 25, 12, 0, 30)
    tracker = Flare::ErrorTracker.new(configuration: @configuration, clock: clock, logger: Logger.new(IO::NULL))
    tracker.apply_rules({ "error_tracking" => true })
    error = raised
    (Flare::ErrorTracker::MAX_KEYS + 50).times do |i|
      tracker.report(error.dup.tap { |e| e.set_backtrace(error.backtrace) }, handled: false, context: { operation: "op#{i}" })
    end

    storage = Flare::MetricStorage.new
    tracker.record(storage)
    rows = storage.drain
    assert_equal Flare::ErrorTracker::MAX_KEYS + 1, rows.size
    overflow = rows.find { |key, _| key.operation == Flare::ErrorTracker::OVERFLOW_SERVICE }
    assert_equal 50, overflow.last[:count]
  end

  def test_queued_upload_is_skipped_once_tracking_turns_off
    queued = []
    executor = Object.new
    executor.define_singleton_method(:post) { |&block| queued << block }
    tracker = Flare::ErrorTracker.new(configuration: @configuration, uploader: @uploader, executor: executor,
                                      logger: Logger.new(IO::NULL))
    tracker.apply_rules({ "error_tracking" => true })
    tracker.report(raised, handled: false)
    requested = tracker.sample_request
    tracker.apply_rules({ "error_tracking" => true, "error_uploads" => requested.map { |fp| upload_entry(fp) } }, requested: requested)
    assert_equal 1, queued.size

    tracker.apply_rules({ "error_tracking" => false })
    queued.each(&:call)
    assert_empty @uploader.uploads
  end

  private

  def upload_entry(fingerprint)
    { "fingerprint" => fingerprint, "upload_id" => "u1", "key" => "k1", "put_url" => "https://r2.test/k1" }
  end

  def enable
    @tracker.apply_rules({ "error_tracking" => true })
  end

  def flush
    storage = Flare::MetricStorage.new
    @tracker.record(storage)
    storage.drain
  end

  def waiting(fingerprint)
    @tracker.instance_variable_get(:@waiting)[fingerprint]
  end

  def raised(message = "boom")
    raise message
  rescue => e
    e
  end

  def raised_with(klass)
    raise klass, "boom"
  rescue Exception => e # rubocop:disable Lint/RescueException
    e
  end

  def error_at(file, method)
    error = RuntimeError.new("boom")
    error.set_backtrace(["#{Dir.pwd}/#{file}:1:in `#{method}'"])
    error
  end

  def install_span_capture
    Flare::ErrorTracker.current = @tracker
    unless OpenTelemetry::SDK::Trace::Span < Flare::ErrorTracker::SpanExceptionCapture
      OpenTelemetry::SDK::Trace::Span.prepend(Flare::ErrorTracker::SpanExceptionCapture)
    end
  end

  def finished_span(error)
    install_span_capture
    tracer = OpenTelemetry::SDK::Trace::TracerProvider.new.tracer("test")
    span = tracer.start_root_span("GET /users/:id", kind: :server)
    span.record_exception(error)
    span.status = OpenTelemetry::Trace::Status.error(error.class.name)
    span.finish
    span
  end
end
