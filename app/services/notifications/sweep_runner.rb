# frozen_string_literal: true

module Notifications
  class SweepRunner
    class << self
      # Runs a full notification sweep across all sites:
      # 1. Wakes any snoozed notifications whose snoozed_until has elapsed.
      # 2. Marks expired notifications as expired.
      # 3. Evaluates enabled rules for each NetworkSite.
      def run!(site_id: nil)
        woken = wake_snoozed!
        expired = expire_stale!

        sites = site_id.present? ? NetworkSite.where(id: site_id) : NetworkSite.all
        evaluated_sites = 0
        created_count = 0
        deduped_count = 0

        sites.find_each do |site|
          evaluated_sites += 1
          results = Notifications::Engine.evaluate_site!(site)
          results.each do |res|
            if res[:action] == "created"
              created_count += 1
            else
              deduped_count += 1
            end
          end
        end

        {
          ranAt: Time.current.utc.iso8601,
          evaluatedSites: evaluated_sites,
          wokenSnoozed: woken,
          expiredCount: expired,
          createdCount: created_count,
          dedupedCount: deduped_count
        }
      end

      def wake_snoozed!
        now = Time.current
        SiteNotification.where(status: "snoozed")
                        .where("snoozed_until IS NOT NULL AND snoozed_until <= ?", now)
                        .update_all(status: "active", snoozed_until: nil, updated_at: now)
      end

      def expire_stale!
        now = Time.current
        SiteNotification.where(status: %w[active seen snoozed])
                        .where("expires_at IS NOT NULL AND expires_at <= ?", now)
                        .update_all(status: "expired", resolved_at: now, updated_at: now)
      end
    end
  end
end
