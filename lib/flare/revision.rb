# frozen_string_literal: true

module Flare
  # Works out the deployed revision of the app this client runs in, usually a
  # git SHA. Flare.configuration.revision calls it once, the first time the
  # revision is asked for; it's sent as X-Client-Revision so the server can
  # mark deploys on the charts.
  #
  # In order:
  #   1. The configured value (config.revision, which defaults to FLARE_REVISION)
  #   2. A platform's variable (Heroku, Render, Railway, Kamal, Fly, ...)
  #   3. A REVISION file in the app root (Capistrano, many Docker builds)
  #   4. git rev-parse HEAD, only when the app root has a .git directory
  # Nil when none of them answer; the server treats a missing header as
  # "unknown".
  module Revision
    MAX_LENGTH = 64

    # Variable => how to read a revision from it (nil: the value as is).
    PLATFORM_VARIABLES = {
      "HEROKU_SLUG_COMMIT" => nil,
      "RENDER_GIT_COMMIT" => nil,
      "RAILWAY_GIT_COMMIT_SHA" => nil,
      "KAMAL_VERSION" => nil,
      # The whole image reference ("registry.fly.io/app:deployment-01J...@sha256:...").
      # Its tag names the deploy, and is the git SHA when deployed with --image-label.
      "FLY_IMAGE_REF" => ->(ref) { ref[%r{:([^:/@]+)(?:@|\z)}, 1] },
      "GIT_SHA" => nil,
      "SOURCE_VERSION" => nil
    }.freeze

    def self.resolve(configured, env: ENV, root: app_root)
      revision = clean(configured) || platform_revision(env) ||
        clean(revision_file(root)) || clean(git_head(root))
      revision&.freeze
    end

    # The first platform variable that holds a revision. Stops there, so a
    # later variable is never parsed.
    def self.platform_revision(env)
      PLATFORM_VARIABLES.each do |name, extract|
        value = env[name]
        value = clean(extract && value ? extract.call(value) : value)
        return value if value
      end
      nil
    end

    # Up to the first line break (CR or LF), stripped and capped, since it
    # goes in a header.
    def self.clean(value)
      value = value.to_s.strip.split(/[\r\n]/, 2).first.to_s.strip
      return if value.empty?

      value[0, MAX_LENGTH]
    end

    def self.app_root
      if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
        ::Rails.root.to_s
      else
        Dir.pwd
      end
    end

    def self.revision_file(root)
      path = File.join(root, "REVISION")
      File.read(path, 256) if File.file?(path)
    rescue StandardError
      nil
    end

    def self.git_head(root)
      return unless File.exist?(File.join(root, ".git"))

      output = IO.popen(["git", "-C", root, "rev-parse", "HEAD"], err: File::NULL, &:read)
      output if $?.success?
    rescue StandardError
      nil
    end
  end
end
