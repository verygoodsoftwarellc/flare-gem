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
  spec.add_dependency "opentelemetry-sdk"
  spec.add_dependency "opentelemetry-instrumentation-rack"
  spec.add_dependency "opentelemetry-instrumentation-net_http"
  spec.add_dependency "opentelemetry-instrumentation-active_support"
  spec.add_dependency "opentelemetry-instrumentation-action_pack"
  spec.add_dependency "opentelemetry-instrumentation-action_view"
  spec.add_dependency "opentelemetry-instrumentation-active_job"
end
