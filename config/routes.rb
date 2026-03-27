# frozen_string_literal: true

Flare::Engine.routes.draw do
  resources :requests, only: [:index, :show]
  resources :jobs, only: [:index, :show]

  # Span category routes
  get "spans/queries", to: "spans#queries", as: :queries_spans
  get "spans/cache", to: "spans#cache", as: :cache_spans
  get "spans/views", to: "spans#views", as: :views_spans
  get "spans/http", to: "spans#http", as: :http_spans
  get "spans/mail", to: "spans#mail", as: :mail_spans
  get "spans/redis", to: "spans#redis", as: :redis_spans
  get "spans/exceptions", to: "spans#exceptions", as: :exceptions_spans
  get "spans/:id", to: "spans#show", as: :span

  delete "clear", to: "requests#clear", as: :clear_data

  root to: "requests#index"
end
