Rails.application.routes.draw do
  devise_for :users
  root "home#index"
  get "up", to: "api#up"
  get "api/up"
  get "api/message"
  post "api/token"
  get "/ping/:token", to: "api#message"
  post "/ping/:token", to: "api#message"

  namespace :api do
    namespace :v1 do
      resources :bulletins, only: [:index]
      resources :inventory, only: [:index, :create, :update, :destroy] do
        collection do
          post :seed_demo
        end
      end
      post "discovery/analyze", to: "discovery#analyze"
      post "discovery/confirm", to: "discovery#confirm"
      post "discovery/resolve", to: "discovery#resolve"
      get "discovery/livetail", to: "discovery#livetail"
      get "discovery/sessions", to: "discovery#sessions"
      post "telemetry/events", to: "telemetry#create"
      get "telemetry/summary", to: "telemetry#summary"
      get "datalake/status", to: "datalake#status"
      post "datalake/sync", to: "datalake#sync"
      get "catalog/clue-index", to: "datalake#clue_index"
      post "notifications/register_token", to: "notifications#register_token"
      post "notifications/dispatch", to: "notifications#dispatch_notifications"
      get "notifications/pending", to: "notifications#pending"
      post "notifications/:id/ack", to: "notifications#ack"
      post "billing/verify", to: "billing#verify"
    end
  end
end
