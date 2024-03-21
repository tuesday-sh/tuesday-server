Rails.application.routes.draw do
  devise_for :users
  root 'home#index'
  get 'api/message'
  post 'api/token'
  get '/ping/:token', to: 'api#message'
  post '/ping/:token', to: 'api#message'
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Defines the root path route ("/")
  # root "articles#index"
end
