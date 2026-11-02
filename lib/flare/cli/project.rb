# frozen_string_literal: true

module Flare
  module CLI
    # What the commands need to know about the app they're run in.
    module Project
      private

      # Also matches /.env*, the rule in a new Rails app's .gitignore.
      def env_ignored?(gitignore)
        gitignore.match?(%r{^/?\.env\*?$})
      end

      def credentials_exist?
        %w[config/credentials.yml.enc config/credentials/production.yml.enc].any? do |path|
          File.exist?(File.join(Dir.pwd, path))
        end
      end
    end
  end
end
