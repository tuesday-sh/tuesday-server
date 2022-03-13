Rails.application.routes.draw do
  get 'home/index'
  post '/api', to: 'api#index'
  post '/ping/:token', to: 'api#ping'
end
