# frozen_string_literal: true

module Flare
  class ApplicationController < ActionController::Base
    protect_from_forgery with: :exception

    layout "flare/application"

    helper_method :show_redis_tab?

    private

    # Only show the Redis tab if:
    # 1. The Redis client library is loaded
    # 2. There are Redis spans in the database
    def show_redis_tab?
      return false unless defined?(::Redis)

      Flare.storage.count_spans_by_category("redis") > 0
    end
  end
end
