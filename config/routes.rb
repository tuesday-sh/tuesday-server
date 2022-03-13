Rails.application.routes.draw do
  post '/api', to: 'api#index'
  post '/ping/:token', to: 'api#ping'
end
