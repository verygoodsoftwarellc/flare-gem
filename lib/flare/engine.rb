# frozen_string_literal: true

module Flare
  class Engine < ::Rails::Engine
    isolate_namespace Flare

    # Load secrets from Rails credentials if not already set via ENV
    initializer "flare.defaults", before: :load_config_initializers do |app|
      ENV["FLARE_KEY"] ||= app.credentials.dig(:flare, :key)
    end

    # Serve static assets from the engine's public directory
    initializer "flare.static_assets" do |app|
      app.middleware.use(
        Rack::Static,
        urls: ["/flare-assets"],
        root: root.join("public"),
        cascade: true
      )
    end

    # Phase 1: Configure OTel SDK and instrumentations before middleware is
    # built so Rack/ActionPack can insert their middleware.
    initializer "flare.opentelemetry", before: :build_middleware_stack do
      Flare.configure_opentelemetry
    end

    # Phase 2: Start the metrics flusher after all initializers have run
    # so user config (metrics_enabled, flush_interval, etc.) is applied.
    config.after_initialize do
      Flare.start_metrics_flusher
    end

    # Auto-mount routes in development/test
    initializer "flare.routes", before: :add_routing_paths do |app|
      if Rails.env.development? || Rails.env.test?
        app.routes.prepend do
          mount Flare::Engine => "/flare"
        end
      end
    end
  end
end
