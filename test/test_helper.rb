# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "fileutils"
require "tmpdir"

# Load OpenTelemetry first
require "opentelemetry/sdk"

# Don't load Rails engine for unit tests - just test the core library
require "flare/version"
require "flare/configuration"
require "flare/sqlite_exporter"
require "flare/storage"
