# frozen_string_literal: true

module Flare
  class JobsController < ApplicationController
    around_action :untrace_request

    helper_method :current_section, :page_title

    PER_PAGE = 50

    def index
      @offset = params[:offset].to_i
      filter_params = {
        name: params[:name].presence
      }
      # Fetch one extra to know if there's a next page
      jobs = Flare.storage.list_jobs(**filter_params, limit: PER_PAGE + 1, offset: @offset)
      @total_count = Flare.storage.count_jobs(**filter_params)
      @has_next = jobs.size > PER_PAGE
      @jobs = jobs.first(PER_PAGE)
      @has_prev = @offset > 0
    end

    def show
      @job = Flare.storage.find_job(params[:id])

      if @job.blank?
        redirect_to jobs_path, alert: "Job not found"
        return
      end

      @spans = Flare.storage.spans_for_trace(params[:id])

      # Find the root span (the job itself) with full properties
      @root_span = @spans.find { |s| s[:parent_span_id] == Flare::MISSING_PARENT_ID }

      # Child spans (everything except the root)
      @child_spans = @spans.reject { |s| s[:parent_span_id] == Flare::MISSING_PARENT_ID }
    end

    private

    def untrace_request
      Flare.untraced { yield }
    end

    def current_section
      "jobs"
    end

    def page_title
      "Jobs"
    end
  end
end
