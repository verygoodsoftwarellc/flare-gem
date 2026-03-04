# frozen_string_literal: true

require "securerandom"
require "digest"
require "base64"
require "socket"
require "net/http"
require "uri"
require "json"
require "fileutils"
require_relative "output"

module Caboose
  class SetupCommand
    include CLI::Output

    DEFAULT_HOST = "https://caboose.dev"
    TIMEOUT_SECONDS = 300 # 5 minutes

    INITIALIZER_CONTENT = <<~RUBY
      # frozen_string_literal: true

      Caboose.configure do |config|
        # ── Spans (local development dashboard) ────────────────────────────
        # Spans capture detailed trace data and are stored in a local SQLite
        # database. Enabled by default in development only. Visit /caboose in
        # your browser to see the dashboard.

        # Enable or disable spans (default: true in development)
        # config.spans_enabled = true

        # How long to keep spans in hours (default: 24)
        # config.retention_hours = 24

        # Maximum number of spans to store (default: 10000)
        # config.max_spans = 10000

        # Path to the SQLite database (default: db/caboose.sqlite3)
        # config.database_path = Rails.root.join("db", "caboose.sqlite3").to_s

        # Ignore specific requests (receives a Rack::Request, return true to ignore)
        # config.ignore_request = ->(request) {
        #   request.path.start_with?("/health")
        # }

        # ── Metrics (remote monitoring) ────────────────────────────────────
        # Metrics aggregate span data into counts, durations, and error rates.
        # Enabled by default in development and production (disabled in test).
        # Sent to caboose.dev when CABOOSE_KEY is configured.

        # Enable or disable metrics (default: true except in test)
        # config.metrics_enabled = true

        # How often to flush metrics in seconds (default: 60)
        # config.metrics_flush_interval = 60

        # ── Custom Instrumentation ─────────────────────────────────────────
        # Subscribe to additional notification prefixes (default: ["app."])
        # config.subscribe_patterns << "mycompany."
      end

      # ════════════════════════════════════════════════════════════════════════
      # Custom Instrumentation
      # ════════════════════════════════════════════════════════════════════════
      #
      # Use ActiveSupport::Notifications.instrument with an "app." prefix
      # anywhere in your code. Caboose captures these in development and
      # displays them in the dashboard.
      #
      #   ActiveSupport::Notifications.instrument("app.geocoding", address: address) do
      #     geocoder.lookup(address)
      #   end
      #
      #   ActiveSupport::Notifications.instrument("app.stripe.charge", amount: 1000) do
      #     Stripe::Charge.create(amount: 1000, currency: "usd")
      #   end
    RUBY

    def initialize(force: false)
      @force = force
    end

    def run
      authenticate
      create_initializer
      add_gitignore_entries

      puts
      puts "#{green("Setup complete!")}"
      puts
      puts bold("What's next:")
      puts "  1. Start your Rails server (#{dim("bin/rails server")})"
      puts "  2. Make a few requests to your app"
      puts "  3. Visit #{bold("/caboose")} to see the dashboard"
      puts
      puts dim("  The dashboard auto-mounts at /caboose in development.")
      puts dim("  Metrics are sent to caboose.dev when CABOOSE_KEY is configured.")
      puts
      puts "  Run #{bold("caboose doctor")} to verify your setup."
      puts "  Run #{bold("caboose status")} to see your configuration."
    rescue Interrupt
      puts
      puts "Setup cancelled."
      exit 1
    end

    private

    # --- Auth ---

    def authenticate
      env_path = File.join(Dir.pwd, ".env")

      if !@force && File.exist?(env_path) && File.read(env_path).match?(/^CABOOSE_KEY=.+/)
        puts "#{checkmark} CABOOSE_KEY already set in .env, skipping auth."
        puts "  Run with --force to re-authenticate."
        return
      end

      server = nil
      state = SecureRandom.hex(32)
      code_verifier = SecureRandom.urlsafe_base64(32)
      code_challenge = Base64.urlsafe_encode64(
        Digest::SHA256.digest(code_verifier),
        padding: false
      )

      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]

      host = ENV.fetch("CABOOSE_HOST", DEFAULT_HOST)
      authorize_url = "#{host}/cli/authorize?state=#{state}&port=#{port}&code_challenge=#{code_challenge}"

      puts "Opening browser to authorize Caboose..."
      open_browser(authorize_url)
      puts
      puts "If the browser didn't open, visit:"
      puts "  #{authorize_url}"
      puts
      puts "Waiting for authorization (up to 5 minutes)..."

      auth_code = wait_for_callback(server, state, TIMEOUT_SECONDS)

      unless auth_code
        puts "Timed out waiting for authorization."
        exit 1
      end

      token = exchange_code(auth_code, code_verifier)
      save_token(token)
    ensure
      server&.close
    end

    def wait_for_callback(server, expected_state, timeout)
      deadline = Time.now + timeout

      while Time.now < deadline
        readable = IO.select([server], nil, nil, 1)
        next unless readable

        client = server.accept
        request_line = client.gets

        unless request_line&.start_with?("GET /callback")
          client.print "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n"
          client.close
          next
        end

        # Read remaining headers (required by HTTP spec)
        while (line = client.gets) && line != "\r\n"; end

        params = parse_query_string(request_line)
        returned_state = params["state"]
        code = params["code"]
        error = params["error"]

        if error
          client.print http_response(error_page(error))
          client.close
          return nil
        elsif returned_state != expected_state
          client.print http_response(error_page("State mismatch. Please try again."))
          client.close
          return nil
        elsif code.nil? || code.empty?
          client.print http_response(error_page("No authorization code received."))
          client.close
          return nil
        else
          client.print http_response(success_page)
          client.close
          return code
        end
      end

      nil
    end

    def parse_query_string(request_line)
      return {} unless request_line
      path = request_line.split(" ")[1]
      return {} unless path
      query = URI(path).query
      return {} unless query
      URI.decode_www_form(query).to_h
    end

    def http_response(body)
      "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
    end

    def exchange_code(auth_code, code_verifier)
      host = ENV.fetch("CABOOSE_HOST", DEFAULT_HOST)
      uri = URI("#{host}/api/cli/exchange")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"

      request = Net::HTTP::Post.new(uri.path)
      request["Content-Type"] = "application/x-www-form-urlencoded"
      request.set_form_data(code: auth_code, code_verifier: code_verifier)

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        $stderr.puts "Failed to exchange code for token: #{response.code} #{response.message}"
        $stderr.puts response.body if response.body
        exit 1
      end

      data = JSON.parse(response.body)
      token = data["token"]

      if token.nil? || token.empty?
        $stderr.puts "No token received from server."
        exit 1
      end

      token
    end

    # --- Token storage ---

    def save_token(token)
      puts
      puts "Where would you like to save the token?"
      puts "  1. .env file"
      puts "  2. Rails credentials"
      puts "  3. Print token"
      print "Choose (1/2/3): "

      choice = $stdin.gets&.strip

      case choice
      when "1"
        @saved_to_dotenv = true
        save_to_dotenv(token)
      when "2"
        print_credentials_instructions(token)
      when "3"
        print_token(token)
      else
        puts "Invalid choice."
        save_token(token)
      end
    end

    def save_to_dotenv(token)
      env_path = File.join(Dir.pwd, ".env")

      if File.exist?(env_path)
        contents = File.read(env_path)
        if contents.match?(/^CABOOSE_KEY=/)
          contents.gsub!(/^CABOOSE_KEY=.*$/, "CABOOSE_KEY=#{token}")
        else
          contents = contents.chomp + "\nCABOOSE_KEY=#{token}\n"
        end
        File.write(env_path, contents)
        puts "  Token saved to .env"
      else
        print "  .env file not found. Create it? (y/n): "
        answer = $stdin.gets&.strip&.downcase
        if answer == "y" || answer == "yes"
          File.write(env_path, "CABOOSE_KEY=#{token}\n")
          puts "  Created .env with CABOOSE_KEY"
        else
          print_dotenv_instructions(token)
        end
      end
    end

    def print_dotenv_instructions(token)
      puts
      puts "Add the following to your .env file:"
      puts
      puts "  CABOOSE_KEY=#{token}"
      puts
      puts "Make sure .env is loaded in your app, for example with the dotenv gem:"
      puts
      puts "  # Gemfile"
      puts "  gem \"dotenv-rails\", groups: [:development, :test]"
    end

    def print_credentials_instructions(token)
      puts
      puts "Add the following to your Rails credentials:"
      puts
      puts "  bin/rails credentials:edit"
      puts
      puts "  caboose:"
      puts "    key: #{token}"
      puts
      puts "Or for a specific environment:"
      puts
      puts "  bin/rails credentials:edit --environment production"
      puts
      puts "  caboose:"
      puts "    key: #{token}"
      puts
    end

    def print_token(token)
      puts
      puts "  CABOOSE_KEY=#{token}"
    end

    # --- Project setup ---

    def create_initializer
      path = File.join(Dir.pwd, "config/initializers/caboose.rb")
      existed = File.exist?(path)

      if existed && !@force
        puts "#{checkmark} config/initializers/caboose.rb already exists"
        puts "  Run with --force to overwrite."
        return
      end

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, INITIALIZER_CONTENT)

      if existed
        puts "#{checkmark} Overwrote config/initializers/caboose.rb"
      else
        puts "#{checkmark} Created config/initializers/caboose.rb"
      end
    end

    def add_gitignore_entries
      gitignore_path = File.join(Dir.pwd, ".gitignore")
      return unless File.exist?(gitignore_path)

      contents = File.read(gitignore_path)
      entries_to_add = []

      entries_to_add << ".env" if @saved_to_dotenv && !contents.match?(/^\.env$/)
      entries_to_add << "/db/caboose.sqlite3*" unless contents.include?("/db/caboose.sqlite3*")

      return if entries_to_add.empty?

      File.open(gitignore_path, "a") do |f|
        f.puts "" unless contents.end_with?("\n")
        entries_to_add.each { |entry| f.puts entry }
      end

      puts "#{checkmark} Added #{entries_to_add.join(", ")} to .gitignore"
    end

    # --- Browser ---

    def open_browser(url)
      case RUBY_PLATFORM
      when /darwin/ then system("open", url)
      when /linux/ then system("xdg-open", url)
      when /mingw|mswin/ then system("start", url)
      end
    end

    def success_page
      page_shell("Authorized!", "You can close this window.")
    end

    def error_page(message)
      escaped = message.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
      page_shell("Error", escaped)
    end

    def page_shell(title, subtitle)
      <<~HTML
        <!DOCTYPE html>
        <html>
        <head><title>Caboose</title></head>
        <body style="font-family: system-ui, -apple-system, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background-color: #f5f3ef;">
          <div style="text-align: center; background: #fff; border-radius: 16px; padding: 48px 56px; box-shadow: 0 1px 3px rgba(0,0,0,0.04), 0 4px 12px rgba(0,0,0,0.04);">
            <h1 style="color: #3d3529; font-size: 28px; font-weight: 700; margin: 0 0 8px;">#{title}</h1>
            <p style="color: #8a8078; font-size: 15px; margin: 0;">#{subtitle}</p>
          </div>
        </body>
        </html>
      HTML
    end
  end
end
