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
      get "discovery/livetail", to: "discovery#livetail"
      post "billing/verify", to: "billing#verify"
    end
  end
end
