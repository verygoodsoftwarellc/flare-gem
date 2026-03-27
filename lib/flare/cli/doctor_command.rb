# frozen_string_literal: true

require_relative "output"

module Flare
  class DoctorCommand
    include CLI::Output

    def run
      puts bold("Flare Doctor")
      puts

      results = []
      results << check_initializer
      results << check_key
      results << check_gitignore
      results << check_database if spans_expected?

      puts
      if results.all?
        puts green("Everything looks good!")
      else
        puts "Run #{bold("flare setup")} to fix issues."
      end
    end

    private

    def check_initializer
      path = File.join(Dir.pwd, "config/initializers/flare.rb")
      if File.exist?(path)
        puts "  #{checkmark} Initializer exists"
        true
      else
        puts "  #{xmark} Initializer not found"
        puts "    Run #{bold("flare setup")} to create one"
        false
      end
    end

    def check_key
      if key_configured?
        puts "  #{checkmark} FLARE_KEY configured"
        true
      elsif credentials_exist?
        puts "  #{checkmark} FLARE_KEY not in ENV or .env (may be in Rails credentials)"
        true
      else
        puts "  #{xmark} FLARE_KEY not found"
        puts "    Run #{bold("flare setup")} to authenticate"
        false
      end
    end

    def check_gitignore
      gitignore_path = File.join(Dir.pwd, ".gitignore")

      unless File.exist?(gitignore_path)
        puts "  #{warn_mark} No .gitignore file found"
        return true
      end

      contents = File.read(gitignore_path)
      missing = []
      missing << ".env" unless contents.match?(/^\.env$/)
      missing << "flare.sqlite3*" unless contents.include?("flare.sqlite3")

      if missing.empty?
        puts "  #{checkmark} .gitignore entries present"
        true
      else
        puts "  #{warn_mark} .gitignore missing: #{missing.join(", ")}"
        puts "    Run #{bold("flare setup")} to add them"
        false
      end
    end

    def check_database
      db_path = File.join(Dir.pwd, "db", "flare.sqlite3")
      db_dir = File.dirname(db_path)

      if File.exist?(db_path)
        if File.writable?(db_path)
          puts "  #{checkmark} Database exists and is writable"
          true
        else
          puts "  #{xmark} Database exists but is not writable"
          puts "    Check file permissions on #{db_path}"
          false
        end
      elsif File.exist?(db_dir) && File.writable?(db_dir)
        puts "  #{checkmark} Database directory is writable (will be created on first request)"
        true
      else
        puts "  #{warn_mark} Database directory #{db_dir} does not exist"
        puts "    It will be created when you start your Rails server"
        true
      end
    end

    def key_configured?
      return true if ENV["FLARE_KEY"] && !ENV["FLARE_KEY"].empty?

      env_path = File.join(Dir.pwd, ".env")
      File.exist?(env_path) && File.read(env_path).match?(/^FLARE_KEY=.+/)
    end

    def credentials_exist?
      %w[config/credentials.yml.enc config/credentials/production.yml.enc].any? do |path|
        File.exist?(File.join(Dir.pwd, path))
      end
    end

    def spans_expected?
      # In production, spans are off by default — skip database check
      env = ENV.fetch("RAILS_ENV", "development")
      return false if env == "production"

      # If explicitly disabled in the initializer, skip database check
      init_path = File.join(Dir.pwd, "config/initializers/flare.rb")
      if File.exist?(init_path)
        content = File.read(init_path)
        return false if content.match?(/^\s*config\.spans_enabled\s*=\s*false/)
      end

      true
    end
  end
end
