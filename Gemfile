# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in flare.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "minitest", "~> 5.16"
gem "rack-test"
gem "puma"

# Allow testing with different Rails versions via RAILS_VERSION env var
rails_version = ENV.fetch("RAILS_VERSION", "~> 7.0")

gem "railties", rails_version
gem "activesupport", rails_version
gem "actionpack", rails_version
gem "activerecord", rails_version
gem "activejob", rails_version

# sqlite3 version depends on Rails version
# Rails 6.x and 7.0-7.1 require sqlite3 ~> 1.4
# Rails 7.2+ supports sqlite3 >= 2.0
if rails_version.include?("6.") || rails_version.include?("7.0") || rails_version.include?("7.1")
  gem "sqlite3", "~> 1.4"
else
  gem "sqlite3", ">= 2.0"
end

gem "openssl"
