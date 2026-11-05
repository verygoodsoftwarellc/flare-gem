# frozen_string_literal: true

module Flare
  module CLI
    # What the commands need to know about the app they're run in.
    module Project
      private

      # Also matches /.env*, the rule in a new Rails app's .gitignore. The last
      # rule wins, as it does in git, so a later !.env means it isn't ignored.
      def env_ignored?(gitignore)
        last_rule = gitignore.scan(%r{^!?/?\.env\*?$}).last
        !last_rule.nil? && !last_rule.start_with?("!")
      end

      # A FLARE_KEY in .env, whether setup saved it there or someone added it
      # by hand. Setup and doctor both treat that .env as needing to be ignored.
      def key_in_dotenv?
        env_path = File.join(Dir.pwd, ".env")
        File.exist?(env_path) && File.read(env_path).match?(/^FLARE_KEY=.+/)
      end

      def credentials_exist?
        Dir.glob("config/credentials{.yml.enc,/*.yml.enc}", base: Dir.pwd).any?
      end
    end
  end
end
