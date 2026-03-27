# frozen_string_literal: true

module Flare
  module ApplicationHelper
    def span_category(span)
      name = span[:name].to_s.downcase
      case name
      when /sql\.active_record/, /mysql/, /postgres/, /sqlite/
        "sql"
      when /cache/
        "cache"
      when /render/, /view/
        "view"
      when /http/, /net_http/, /faraday/
        "http"
      when /mail/
        "mailer"
      when /job/, /active_job/
        "job"
      when /action_controller/, /process_action/
        "controller"
      else
        "other"
      end
    end

    def span_display_info(span, category)
      props = span[:properties] || {}
      case category
      when "queries"
        stmt = props["db.statement"]&.to_s
        name = props["name"]&.to_s
        db_name = props["db.name"]&.to_s
        source_loc = if props["code.filepath"] && props["code.lineno"]
          "#{props["code.filepath"]}:#{props["code.lineno"]}"
        end
        secondary = [name.presence, db_name.presence, source_loc].compact.join(" \u00b7 ").presence
        if stmt.present?
          { primary: stmt, secondary: secondary }
        elsif name.present?
          { primary: name, secondary: [db_name.presence, source_loc].compact.join(" \u00b7 ").presence }
        else
          { primary: span[:name], secondary: [db_name.presence, source_loc].compact.join(" \u00b7 ").presence }
        end
      when "cache"
        key = props["key"]&.to_s
        op = span[:name].to_s.sub(".active_support", "").sub("cache_", "")
        store = props["store"]&.to_s&.sub(/^ActiveSupport::Cache::/, "")
        { primary: key.presence || span[:name], secondary: store, cache_op: op }
      when "views"
        identifier = props["identifier"] || props["code.filepath"]
        primary = identifier ? identifier.to_s.sub(/^.*\/app\/views\//, "") : span[:name]
        { primary: primary, secondary: nil }
      when "http"
        full_url = props["http.url"] || ""
        target = props["http.target"] || ""
        host = props["http.host"] || props["net.peer.name"] || props["peer.service"]
        uri = URI.parse(full_url) rescue nil
        if uri && uri.host
          domain = uri.host
          path = uri.path.presence || "/"
          path = "#{path}?#{uri.query}" if uri.query.present?
        else
          domain = host
          path = target.presence || full_url
        end
        method = props["http.method"]
        status = props["http.status_code"]
        { primary: path.to_s.truncate(100), secondary: domain, http_method: method, http_status: status }
      when "mail"
        mailer = props["mailer"]
        action = props["action"]
        subject = props["subject"]
        if mailer && action
          { primary: "#{mailer}##{action}", secondary: subject }
        else
          { primary: span[:name], secondary: nil }
        end
      when "redis"
        cmd = props["db.statement"]&.to_s
        { primary: cmd.presence || span[:name], secondary: nil }
      when "exceptions"
        exc_type = span[:exception_type]
        exc_message = span[:exception_message]
        primary = if exc_type.present? && exc_message.present?
          "#{exc_type}: #{exc_message}"
        elsif exc_message.present?
          exc_message
        elsif exc_type.present?
          exc_type
        else
          span[:name]
        end
        stacktrace = span[:exception_stacktrace].to_s
        first_app_line = stacktrace.split("\n").find { |line| line.include?("/app/") } || stacktrace.split("\n").first
        secondary = first_app_line&.strip.to_s.truncate(200)
        { primary: primary, secondary: secondary }
      else
        { primary: span[:name], secondary: nil }
      end
    end

    def format_duration(ms)
      return "-" if ms.nil?

      if ms >= 1000
        "#{(ms / 1000.0).round(1)}s"
      else
        "#{ms.round(1)}ms"
      end
    end

    def format_content(data, indent = 0)
      return "" if data.nil?

      lines = []
      prefix = "  " * indent

      case data
      when Hash
        data.each do |key, value|
          if value.is_a?(Hash) || value.is_a?(Array)
            lines << "#{prefix}#{key}:"
            lines << format_content(value, indent + 1)
          else
            formatted_value = format_value(value)
            if formatted_value.include?("\n")
              lines << "#{prefix}#{key}:"
              formatted_value.each_line do |line|
                lines << "#{prefix}  #{line.rstrip}"
              end
            else
              lines << "#{prefix}#{key}: #{formatted_value}"
            end
          end
        end
      when Array
        data.each do |item|
          if item.is_a?(Hash) || item.is_a?(Array)
            lines << "#{prefix}-"
            lines << format_content(item, indent + 1)
          else
            lines << "#{prefix}- #{format_value(item)}"
          end
        end
      else
        lines << "#{prefix}#{format_value(data)}"
      end

      lines.join("\n")
    end

    private

    def format_value(value)
      case value
      when nil
        "null"
      when true, false
        value.to_s
      when Numeric
        value.to_s
      else
        value.to_s
      end
    end
  end
end
