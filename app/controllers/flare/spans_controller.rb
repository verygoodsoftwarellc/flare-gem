# frozen_string_literal: true

module Flare
  class SpansController < ApplicationController
    around_action :untrace_request

    helper_method :current_section, :page_title, :category_config

    PER_PAGE = 50

    CATEGORIES = {
      "queries" => { title: "Queries", icon: "database", badge_class: "sql" },
      "cache" => { title: "Cache", icon: "archive", badge_class: "cache" },
      "views" => { title: "Views", icon: "layout", badge_class: "view" },
      "http" => { title: "HTTP", icon: "globe", badge_class: "http" },
      "mail" => { title: "Mail", icon: "mail", badge_class: "mail" },
      "redis" => { title: "Redis", icon: "database", badge_class: "other" },
      "exceptions" => { title: "Exceptions", icon: "alert-triangle", badge_class: "exception" }
    }.freeze

    def queries
      list_spans("queries")
    end

    def cache
      list_spans("cache")
    end

    def views
      list_spans("views")
    end

    def http
      list_spans("http")
    end

    def mail
      list_spans("mail")
    end

    def redis
      list_spans("redis")
    end

    def exceptions
      list_spans("exceptions")
    end

    def show
      @span = Flare.storage.find_span(params[:id])

      if @span.blank?
        redirect_to requests_path, alert: "Span not found"
        return
      end

      @category = params[:category]
    end

    private

    def list_spans(category)
      @category = category
      @offset = params[:offset].to_i
      filter_params = { name: params[:name].presence }

      spans = Flare.storage.list_spans_by_category(category, **filter_params, limit: PER_PAGE + 1, offset: @offset)
      @total_count = Flare.storage.count_spans_by_category(category, **filter_params)
      @has_next = spans.size > PER_PAGE
      @spans = spans.first(PER_PAGE)
      @has_prev = @offset > 0

      # Load properties for display
      span_ids = @spans.map { |s| s[:id] }
      if span_ids.any?
        all_properties = Flare.storage.load_properties_for_ids("Flare::Span", span_ids)
        @spans.each do |span|
          span[:properties] = all_properties[span[:id]] || {}
        end
      end

      render :index
    end

    def untrace_request
      Flare.untraced { yield }
    end

    def current_section
      @category || "spans"
    end

    def page_title
      category_config[:title]
    end

    def category_config
      CATEGORIES[@category] || { title: "Spans", icon: "activity", badge_class: "other" }
    end
  end
end
