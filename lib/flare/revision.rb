# frozen_string_literal: true

module Flare
  # The deployed revision of the app this client runs in, usually a git SHA.
  # Sent as X-Client-Revision so the server can mark deploys on the charts.
  #
  # Resolved once, the first time it's asked for, and frozen. In order:
  #   1. Flare.configure { |c| c.revision = "..." } or FLARE_REVISION
  #   2. A platform's variable (Heroku, Render, Railway, Kamal, Fly, ...)
  #   3. A REVISION file in the app root (Capistrano, many Docker builds)
  #   4. git rev-parse HEAD, only when the app root has a .git directory
  # Nil when none of them answer; the server treats a missing header as
  # "unknown".
  module Revision
    MAX_LENGTH = 64

    PLATFORM_VARIABLES = %w[
      HEROKU_SLUG_COMMIT
      RENDER_GIT_COMMIT
      RAILWAY_GIT_COMMIT_SHA
      KAMAL_VERSION
      FLY_IMAGE_REF
      GIT_SHA
      SOURCE_VERSION
    ].freeze

    @mutex = Mutex.new
    @resolved = false
    @current = nil

    def self.current
      return @current if @resolved

      @mutex.synchronize do
        unless @resolved
          @current = resolve
          @resolved = true
        end
      end
      @current
    end

    def self.resolve(configured: configured_revision, env: ENV, root: app_root)
      candidates = [configured, env["FLARE_REVISION"]]
      candidates.concat(PLATFORM_VARIABLES.map { |name| env[name] })

      revision = candidates.map { |value| clean(value) }.find { |value| value }
      revision ||= clean(revision_file(root))
      revision ||= clean(git_head(root))
      revision&.freeze
    end

    # Forget the resolved value. For tests.
    def self.reset!
      @mutex.synchronize do
        @resolved = false
        @current = nil
      end
    end

    def self.clean(value)
      value = value.to_s.strip
      return if value.empty?

      value[0, MAX_LENGTH]
    end

    def self.configured_revision
      Flare.configuration.revision if Flare.respond_to?(:configuration)
    end

    def self.app_root
      if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
        ::Rails.root.to_s
      else
        Dir.pwd
      end
    rescue StandardError
      Dir.pwd
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
