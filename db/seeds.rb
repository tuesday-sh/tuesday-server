# This file should contain all the record creation needed to seed the database with its default values.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Examples:
#
#   movies = Movie.create([{ name: "Star Wars" }, { name: "Lord of the Rings" }])
#   Character.create(name: "Luke", movie: movies.first)
if ENV["SEED_USER_EMAIL"].present? && ENV["SEED_USER_PASS"].present?
  User.find_or_create_by(email: ENV["SEED_USER_EMAIL"]) do |u|
    u.password = ENV["SEED_USER_PASS"]
  end
end

begin
  DataLake::GoldSyncJob.perform_now
rescue StandardError => e
  Rails.logger.warn("[db:seed] DataLake::GoldSyncJob skipped: #{e.message}")
end