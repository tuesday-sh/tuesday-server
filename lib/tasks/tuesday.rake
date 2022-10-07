namespace :tuesday do 

  desc "Create an API Token and assign it to a user by id"
  task :create_api_token_for_user => :environment  do |t, args|
    user = User.find(1)
    puts "User #{user.email}"
    user.api_keys.create! token: SecureRandom.hex
  end
end
