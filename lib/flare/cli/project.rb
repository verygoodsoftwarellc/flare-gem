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

      def credentials_exist?
        Dir.glob("config/credentials{.yml.enc,/*.yml.enc}", base: Dir.pwd).any?
      end
    end
  end
end
