# frozen_string_literal: true

require_relative "lib/flare/version"

Gem::Specification.new do |spec|
  spec.name = "flare"
  spec.version = Flare::VERSION
  spec.authors = ["John Nunemaker"]
  spec.email = ["nunemaker@gmail.com"]

  spec.summary = "Light up what's slowing you down"
  spec.description = "App monitoring for Rails. Captures requests, queries, jobs, cache, views, HTTP calls, mail, and exceptions with a waterfall visualization dashboard."
  spec.homepage = "https://github.com/verygoodsoftwarellc/flare-gem"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata["homepage_uri"] = "https://flare.am"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/releases"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"] = "#{spec.homepage}#readme"

  spec.files = Dir.chdir(__dir__) do
    Dir["{app,config,exe,lib,public}/**/*", "CHANGELOG.md", "LICENSE.txt", "README.md"].reject { |f| File.directory?(f) }
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "railties", ">= 7.0"
  spec.add_dependency "activesupport", ">= 7.0"
  spec.add_dependency "actionpack", ">= 7.0"
  spec.add_dependency "concurrent-ruby", ">= 1.1"
  # Floors are the oldest versions CI installs (the Ruby 3.0 rows). The
  # pre-1.0 instrumentation gems stay below 1.0 until Flare is tested on it.
  spec.add_dependency "opentelemetry-sdk", "~> 1.7"
  spec.add_dependency "opentelemetry-instrumentation-rack", "~> 0.25"
  spec.add_dependency "opentelemetry-instrumentation-net_http", "~> 0.22"
  spec.add_dependency "opentelemetry-instrumentation-active_support", "~> 0.7"
  spec.add_dependency "opentelemetry-instrumentation-action_pack", "~> 0.10"
  spec.add_dependency "opentelemetry-instrumentation-action_view", "~> 0.8"
  spec.add_dependency "opentelemetry-instrumentation-active_job", "~> 0.7"
end
