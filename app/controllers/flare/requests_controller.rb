# frozen_string_literal: true

module Flare
  class RequestsController < ApplicationController
    around_action :untrace_request

    helper_method :current_section, :page_title, :current_origin

    PER_PAGE = 50

    def index
      @offset = params[:offset].to_i
      filter_params = {
        status: params[:status].presence,
        method: params[:method].presence,
        name: params[:name].presence,
        origin: current_origin
      }
      # Fetch one extra to know if there's a next page
      requests = Flare.storage.list_requests(**filter_params, limit: PER_PAGE + 1, offset: @offset)
      @total_count = Flare.storage.count_requests(**filter_params)
      @has_next = requests.size > PER_PAGE
      @requests = requests.first(PER_PAGE)
      @has_prev = @offset > 0
    end

    def show
      @request = Flare.storage.find_request(params[:id])

      if @request.blank?
        redirect_to requests_path, alert: "Request not found"
        return
      end

      @spans = Flare.storage.spans_for_trace(params[:id])

      # Find the root span (the request itself) with full properties
      @root_span = @spans.find { |s| s[:parent_span_id] == Flare::MISSING_PARENT_ID }

      # Child spans (everything except the root)
      @child_spans = @spans.reject { |s| s[:parent_span_id] == Flare::MISSING_PARENT_ID }
    end

    def clear
      Flare.storage.clear_all
      redirect_to root_path
    end

    private

    def untrace_request
      Flare.untraced { yield }
    end

    def current_section
      "requests"
    end

    def page_title
      "Requests"
    end

    def current_origin
      # If origin was explicitly set (even to empty for "All"), use that
      if params.key?(:origin)
        return params[:origin].presence  # nil for "All Origins", "app" or "rails" otherwise
      end

      # Default to "app" to hide Rails framework noise
      "app"
    end
  end
end
