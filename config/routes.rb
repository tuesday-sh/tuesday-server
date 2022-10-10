Rails.application.routes.draw do
  root 'home#index'
  get 'api/message'
  get '/ping/:token', to: 'api#message'
  post '/ping/:token', to: 'api#message'
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Defines the root path route ("/")
  # root "articles#index"
end
