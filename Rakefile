# frozen_string_literal: true

require "bundler/gem_tasks"

# `rake release` builds, tags and pushes the tag. GitHub Actions
# (.github/workflows/release.yml) publishes the gem to RubyGems.
ENV["gem_push"] ||= "no"
require "minitest/test_task"

Minitest::TestTask.create

task default: :test
