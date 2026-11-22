# frozen_string_literal: true

module Notifications
  # Bridges Gold Data Lake advisories (CVEs, KEVs, CPSC recalls, firmware releases, EOL)
  # into canonical `SiteNotification` records (kind: "advisory") with interrupt-vs-rollup rules:
  # - High-sev (CVE/KEV/Recall): surfaces = ["push", "bulletin"], priority = "critical"
  # - Routine (Firmware/Notice): surfaces = ["bulletin"], priority = "normal" (quiet rollup)
  class GoldAdvisoryBridge
    class << self
      def sync_all_sites!
        sites_evaluated = 0
        created_count = 0
        deduped_count = 0

        NetworkSite.includes(:monitored_devices).find_each do |site|
          next if site.monitored_devices.none?

          sites_evaluated += 1
          res = sync_for_site!(site)
          created_count += res[:createdCount]
          deduped_count += res[:dedupedCount]
        end

        {
          sitesEvaluated: sites_evaluated,
          createdCount: created_count,
          dedupedCount: deduped_count
        }
      end

      def sync_for_site!(site, devices: nil, suppress_push: false)
        return { createdCount: 0, dedupedCount: 0 } if site.nil?

        target_devices = devices.nil? ? site.monitored_devices.to_a : Array(devices)
        return { createdCount: 0, dedupedCount: 0 } if target_devices.empty?

        tracked = target_devices.map(&:to_gold_hash)
        assembled = Bulletins::GoldSnapshotLoader.assemble_bulletins_from_gold(
          app_flavor: "tuesday",
          muted_feed_slugs: site.muted_feed_slugs_list,
          tracked_devices: tracked
        )

        created = 0
        deduped = 0

        Array(assembled[:inbox]).each do |item|
          ext_id = item[:external_id].to_s
          next if ext_id.blank?

          is_high = !!item[:is_high_sev]
          rule_id = is_high ? "gold_critical_cve" : "gold_firmware_update"
          surfaces = (is_high && !suppress_push) ? %w[push bulletin] : %w[bulletin]

          res = Notifications::Engine.emit_for_rule!(
            site: site,
            rule_id: rule_id,
            surfaces_override: surfaces,
            dedup_key: "advisory:#{site.id}:#{ext_id}",
            context: {
              "device_label" => item[:device_label].presence || item[:title].to_s,
              "advisory_summary" => item[:body].to_s,
              "target_version" => item[:target_version].presence || "latest",
              "external_id" => ext_id,
              "bulletin_type" => item[:bulletin_type].to_s,
              "feed_slug" => item[:feed_slug].to_s
            }
          )

          if res[:action] == "created"
            created += 1
          else
            deduped += 1
          end
        end

        { createdCount: created, dedupedCount: deduped }
      end
    end
  end
end
