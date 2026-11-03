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
      resources :inventory, only: [:index]
      post "discovery/analyze", to: "discovery#analyze"
      post "discovery/confirm", to: "discovery#confirm"
    end
  end
end
