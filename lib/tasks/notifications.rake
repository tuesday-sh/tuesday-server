# frozen_string_literal: true

namespace :notifications do
  desc "Run externalized notification sweep (wake snoozed, expire stale, evaluate site rules)"
  task sweep: :environment do
    result = Notifications::SweepRunner.run!(site_id: ENV["SITE_ID"])
    puts "[notifications:sweep] #{result.to_json}"
  end

  desc "Wake snoozed notifications whose snoozed_until timestamp has passed"
  task wake_snoozed: :environment do
    count = Notifications::SweepRunner.wake_snoozed!
    puts "[notifications:wake_snoozed] woken=#{count}"
  end
end
