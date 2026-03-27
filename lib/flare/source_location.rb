# frozen_string_literal: true

module Flare
  # Utility for finding the source location (file, line, method) of app code
  # that triggered a database query or other instrumented operation.
  module SourceLocation
    # How many app code lines to capture for the backtrace
    MAX_TRACE_LINES = 8

    # Patterns to filter out from backtraces (gems, framework code)
    IGNORE_PATTERNS = [
      /\/gems\//,
      /\/ruby\//,
      /\/rubygems\//,
      /lib\/active_record/,
      /lib\/active_support/,
      /lib\/action_/,
      /opentelemetry/,
      /flare/,
      /<internal:/,
      /\/bin\//,
    ].freeze

    module_function

    # Find the first app source location from the current backtrace
    # Returns a hash with :filepath, :lineno, :function or nil
    def find
      backtrace = caller(2, 50)
      return nil unless backtrace

      # Find the first line that's app code (not gems/framework)
      app_line = backtrace.find { |line| app_code?(line) }
      return nil unless app_line

      parse_backtrace_line(app_line)
    end

    # Find multiple app source locations from the current backtrace
    # Returns an array of cleaned backtrace lines (up to MAX_TRACE_LINES)
    def find_trace
      backtrace = caller(2, 100)
      return [] unless backtrace

      # Filter to only app code lines
      app_lines = backtrace.select { |line| app_code?(line) }
      return [] if app_lines.empty?

      # Clean and format each line, limit to MAX_TRACE_LINES
      app_lines.first(MAX_TRACE_LINES).map { |line| clean_backtrace_line(line) }
    end

    # Add source location attributes to a hash (for span attributes)
    def add_to_attributes(attrs)
      location = find
      return attrs unless location

      attrs["code.filepath"] = location[:filepath]
      attrs["code.lineno"] = location[:lineno]
      attrs["code.function"] = location[:function] if location[:function]

      # Add full trace as a single string attribute
      trace = find_trace
      attrs["code.stacktrace"] = trace.join("\n") if trace.any?

      attrs
    end

    def app_code?(line)
      # Must contain /app/ (Rails convention) and not match ignore patterns
      return false unless line.include?("/app/")

      IGNORE_PATTERNS.none? { |pattern| line.match?(pattern) }
    end

    def parse_backtrace_line(line)
      # Parse: /path/to/file.rb:123:in `method_name'
      if line =~ /\A(.+):(\d+):in [`'](.+)'\z/
        {
          filepath: clean_path($1),
          lineno: $2.to_i,
          function: $3
        }
      elsif line =~ /\A(.+):(\d+)\z/
        {
          filepath: clean_path($1),
          lineno: $2.to_i,
          function: nil
        }
      end
    end

    def clean_backtrace_line(line)
      # Parse and reformat: "app/models/user.rb:42:in `find_by_email'"
      if line =~ /\A(.+):(\d+):in [`'](.+)'\z/
        "#{clean_path($1)}:#{$2} in `#{$3}'"
      elsif line =~ /\A(.+):(\d+)\z/
        "#{clean_path($1)}:#{$2}"
      else
        clean_path(line)
      end
    end

    def clean_path(path)
      # Remove Rails.root prefix if present
      if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        path.sub(/\A#{Regexp.escape(Rails.root.to_s)}\//, "")
      else
        path
      end
    end
  end
end
