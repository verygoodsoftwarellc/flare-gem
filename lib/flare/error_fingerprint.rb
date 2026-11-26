# frozen_string_literal: true

require "digest"

module Flare
  # Groups occurrences of the same bug. The fingerprint is the error class plus
  # the top app frames, by file and method only. Line numbers, messages and
  # anything volatile (GUIDs, numbers, generated template method names) stay
  # out, so editing a file or a new record id can't split one bug into many
  # groups.
  module ErrorFingerprint
    FINGERPRINT_FRAMES = 3

    Frame = Struct.new(:file, :line, :method, :app, keyword_init: true) do
      # File and method with the volatile parts taken out, e.g.
      # "app/models/user.rb:save".
      def normalized
        "#{ErrorFingerprint.normalize_file(file)}:#{ErrorFingerprint.normalize_method(method)}"
      end
    end

    # "/path/file.rb:12:in `method'" (Ruby < 3.4) or "in 'Klass#method'" (3.4+).
    BACKTRACE_LINE = /\A(.+?):(\d+)(?::in [`'](.*)')?\z/
    # "block (2 levels) in ", "rescue in ", "ensure in " in front of a label.
    LABEL_PREFIX = /\A(?:(?:block|rescue|ensure)(?: \(\d+ levels\))? in )+/
    UUID = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/
    LONG_HEX = /\b\h{16,}\b/
    DIGITS = /\d+/
    # ".../gems/3.4.0/gems/activerecord-7.2.3/lib/..." -> "activerecord-7.2.3/lib/..."
    GEM_PATH = %r{\A.*/gems/(?:\d[^/]*/gems/)?}
    GEM_VERSION = %r{\A([^/]+?)-\d[^/]*/}
    RUBY_LIB_PATH = %r{\A.*/lib/ruby/(?:\d[^/]*/)?}
    VENDORED = %r{\A(?:vendor|node_modules|tmp)/|/gems/}
    FLARE_LIB = "#{File.expand_path("..", __dir__)}/"

    module_function

    def fingerprint(class_name, frames)
      app = frames.select(&:app)
      # A block around code adds a "block in foo" frame next to "foo"; collapse
      # repeats so wrapping a line in a block doesn't change the group.
      picked = []
      (app.empty? ? frames : app).each do |frame|
        normalized = frame.normalized
        picked << normalized unless picked.last == normalized
        break if picked.size == FINGERPRINT_FRAMES
      end
      Digest::SHA256.hexdigest([normalize_class(class_name), *picked].join("\n"))[0, 16]
    end

    def frames(exception, root: app_root)
      locations = exception.backtrace_locations
      if locations && !locations.empty?
        locations.map { |location| frame(location.absolute_path || location.path, location.lineno, location.label, root) }
      else
        Array(exception.backtrace).filter_map do |line|
          match = BACKTRACE_LINE.match(line.to_s)
          frame(match[1], match[2].to_i, match[3], root) if match
        end
      end
    end

    def frame(path, line, label, root)
      path = path.to_s
      app = app_path?(path, root)
      Frame.new(file: display_path(path, root, app), line: line, method: label.to_s, app: app)
    end

    def app_path?(path, root)
      return false if root.nil? || path.start_with?(FLARE_LIB)
      return false unless path.start_with?(root)

      !path.delete_prefix(root).match?(VENDORED)
    end

    def display_path(path, root, app)
      return path.delete_prefix(root) if app

      if path.match?(GEM_PATH)
        path.sub(GEM_PATH, "")
      elsif path.match?(RUBY_LIB_PATH)
        "ruby/#{path.sub(RUBY_LIB_PATH, "")}"
      elsif root && path.start_with?(root)
        path.delete_prefix(root)
      else
        path
      end
    end

    # Gem versions change on every bundle update; the code that raised doesn't.
    def normalize_file(file)
      file.to_s.sub(GEM_VERSION, '\1/').gsub(UUID, "").gsub(LONG_HEX, "")
    end

    # Bare method name: "block (2 levels) in Users#show" -> "show",
    # "_app_views_users_show_html_erb__1234_5678" -> "_app_views_users_show_html_erb__".
    def normalize_method(label)
      name = label.to_s.sub(LABEL_PREFIX, "")
      name = name.split(/[#.]/).last.to_s if name.match?(/\A[A-Z][\w:]*[#.]/)
      name.gsub(UUID, "").gsub(DIGITS, "")
    end

    # Anonymous classes print as "#<Class:0x000...>".
    def normalize_class(class_name)
      class_name.to_s.gsub(/0x\h+/, "")
    end

    def app_root
      @app_root ||= begin
        root = (Rails.root.to_s if defined?(Rails) && Rails.respond_to?(:root) && Rails.root)
        root ||= Dir.pwd
        root.end_with?("/") ? root : "#{root}/"
      end
    rescue StandardError
      nil
    end
  end
end
