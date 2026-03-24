# frozen_string_literal: true

require_relative "lib/caboose/version"

Gem::Specification.new do |spec|
  spec.name = "caboose"
  spec.version = Caboose::VERSION
  spec.authors = ["John Nunemaker"]
  spec.email = ["nunemaker@gmail.com"]

  spec.summary = "Track what just happened in your Rails app"
  spec.description = "Track what just happened in your Rails app"
  spec.homepage = "https://github.com/jnunemaker/caboose"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/CHANGELOG.md"

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
