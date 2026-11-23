# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

class SubscribePatternsInitializerTest < Minitest::Test
  # The README adds prefixes in config/initializers/flare.rb, which Rails loads
  # after Flare has set up its notification subscriptions. Runs in a
  # subprocess: loading lib/flare.rb here would skip the engine for the
  # integration tests that require Rails later.
  def test_prefix_added_in_an_initializer_is_recorded
    stdout, stderr, status = Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config", "initializers"))
      File.write(File.join(root, "config", "initializers", "flare.rb"), <<~'RUBY')
        Flare.configure do |config|
          config.subscribe_patterns << "mycompany."
          config.subscribe_patterns << "app."
        end
      RUBY

      Open3.capture3(
        { "RAILS_ENV" => "development" },
        RbConfig.ruby, "-Ilib", "-e", script, root,
        chdir: File.expand_path("..", __dir__)
      )
    end

    assert status.success?, stderr
    assert_equal %w[app.default mycompany.custom], stdout.lines.last.split
  end

  private

  def script
    <<~'RUBY'
      root = ARGV.fetch(0)
      require "sqlite3"
      require "rails"
      require "action_controller/railtie"
      require "flare"

      Flare.configure do |config|
        config.database_path = File.join(root, "flare.sqlite3")
        config.metrics_enabled = false
      end

      class SubscribeApp < Rails::Application
        config.root = ARGV.fetch(0)
        config.eager_load = false
        config.logger = Logger.new(nil)
        config.secret_key_base = "test"
      end
      Rails.application.initialize!

      OpenTelemetry.tracer_provider.tracer("test").in_span("job") do
        ActiveSupport::Notifications.instrument("app.default") { nil }
        ActiveSupport::Notifications.instrument("mycompany.custom") { nil }
      end
      abort "flush failed" unless Flare.force_flush == OpenTelemetry::SDK::Trace::Export::SUCCESS

      names = SQLite3::Database.new(Flare.configuration.database_path)
        .execute("SELECT name FROM flare_spans WHERE name LIKE 'app.%' OR name LIKE 'mycompany.%'").flatten
      puts names.sort.join(" ")
    RUBY
  end
end
