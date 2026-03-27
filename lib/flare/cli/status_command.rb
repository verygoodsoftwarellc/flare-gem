# frozen_string_literal: true

require_relative "output"
require_relative "../version"

module Flare
  class StatusCommand
    include CLI::Output

    def run
      puts bold("Flare v#{VERSION}")
      puts

      puts bold("Environment")
      puts "  RAILS_ENV:    #{ENV.fetch("RAILS_ENV", dim("not set"))}"
      puts "  FLARE_KEY:  #{key_status}"
      puts "  FLARE_URL:  #{ENV.fetch("FLARE_URL", dim("https://flare.am (default)"))}"
      puts

      puts bold("Files")
      puts "  Initializer:  #{file_status("config/initializers/flare.rb")}"
      puts "  .env:         #{file_status(".env")}"
      puts "  .gitignore:   #{file_status(".gitignore")}"
      puts "  Database:     #{file_status("db/flare.sqlite3")}"
    end

    private

    def key_status
      if ENV["FLARE_KEY"] && !ENV["FLARE_KEY"].empty?
        green("set via ENV")
      else
        env_path = File.join(Dir.pwd, ".env")
        if File.exist?(env_path) && File.read(env_path).match?(/^FLARE_KEY=.+/)
          green("set in .env")
        else
          red("not configured")
        end
      end
    end

    def file_status(relative_path)
      path = File.join(Dir.pwd, relative_path)
      File.exist?(path) ? green("exists") : dim("not found")
    end
  end
end
