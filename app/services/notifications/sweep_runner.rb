# frozen_string_literal: true

module Notifications
  class SweepRunner
    class << self
      # Runs a full notification sweep across all sites and records a NotificationJobRun audit row:
      # 1. Wakes any snoozed notifications whose snoozed_until has elapsed.
      # 2. Marks expired notifications as expired.
      # 3. Evaluates enabled rules for each NetworkSite.
      def run!(site_id: nil, trigger_source: ENV.fetch("NOTIFICATION_TRIGGER_SOURCE", "rake"))
        job_run = start_job_run!(job_key: "notifications:sweep", trigger_source: trigger_source)

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

        push_summary = Notifications::PushDispatcher.dispatch_pending!

        finish_job_run!(
          job_run,
          evaluated_sites: evaluated_sites,
          created_count: created_count,
          deduped_count: deduped_count,
          woken_snoozed: woken,
          expired_count: expired
        )

        {
          jobRunId: job_run&.id,
          ranAt: Time.current.utc.iso8601,
          triggerSource: trigger_source,
          evaluatedSites: evaluated_sites,
          wokenSnoozed: woken,
          expiredCount: expired,
          createdCount: created_count,
          dedupedCount: deduped_count,
          pushSent: push_summary[:sentCount],
          pushFailed: push_summary[:failedCount],
          pushSkipped: push_summary[:skippedCount]
        }
      rescue StandardError => e
        fail_job_run!(job_run, e)
        raise
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

      private

      def start_job_run!(job_key:, trigger_source:)
        return nil unless defined?(NotificationJobRun) && NotificationJobRun.table_exists?

        NotificationJobRun.create!(
          job_key: job_key,
          trigger_source: trigger_source.to_s,
          status: "running",
          started_at: Time.current
        )
      end

      def finish_job_run!(job_run, attrs)
        return unless job_run

        job_run.update!(attrs.merge(status: "succeeded", finished_at: Time.current))
      end

      def fail_job_run!(job_run, error)
        return unless job_run

        job_run.update!(
          status: "failed",
          finished_at: Time.current,
          error_message: "#{error.class}: #{error.message}"
        )
      rescue StandardError
        nil
      end
    end
  end
end
