# frozen_string_literal: true

module Notifications
  # Deterministic 0-LLM-turn relinker that upgrades previously enrolled MonitoredDevices
  # (with empty or fallback `pkg:generic/enrolled/...` PURLs) whenever new hardware or feeds
  # land in the Gold Catalog, then emits a quiet "Advisory coverage unlocked" Bulletin.
  class CatalogRelinker
    class << self
      def relink_all_sites!
        sites_checked = 0
        relinked_count = 0

        NetworkSite.includes(:monitored_devices).find_each do |site|
          next if site.monitored_devices.none?

          sites_checked += 1
          res = relink_site!(site)
          relinked_count += res[:relinkedCount]
        end

        {
          sitesChecked: sites_checked,
          relinkedCount: relinked_count
        }
      end

      def relink_site!(site)
        return { relinkedCount: 0, devices: [] } if site.nil?

        relinked_devices = []

        site.monitored_devices.each do |device|
          next unless needs_relink?(device)

          resolved = Discovery::HardwareVisionService.resolve_gold_device_identity(
            vendor: device.vendor.to_s,
            model: (device.model_number.presence || device.short_label || device.name).to_s,
            version: device.version.presence || "1.0.0"
          )

          canonical_purls = Array(resolved[:purls]).map(&:to_s).reject do |p|
            p.blank? || p.start_with?("pkg:generic/enrolled/")
          end
          next if canonical_purls.empty?

          device.purls_list = canonical_purls
          if %w[C6 C8].include?(device.category_code.to_s) && resolved[:category_code].present?
            device.category_code = resolved[:category_code]
          end
          device.save!

          # Immediately sync any newly matched Gold advisories (in-app only, no push spam)
          Notifications::GoldAdvisoryBridge.sync_for_site!(site, devices: [device], suppress_push: true)

          # Emit quiet UX delight bulletin so the user sees coverage unlocked automatically
          Notifications::Engine.emit_for_rule!(
            site: site,
            rule_id: "device_coverage_unlocked",
            monitored_device: device,
            dedup_key: "coverage_unlocked:#{site.id}:#{device.id}",
            context: {
              "device_label" => device.short_label.presence || device.name,
              "device_id" => device.external_uuid
            }
          )

          relinked_devices << device.external_uuid
        end

        { relinkedCount: relinked_devices.size, devices: relinked_devices }
      end

      def needs_relink?(device)
        purls = device.purls_list
        purls.empty? || purls.all? { |p| p.to_s.start_with?("pkg:generic/enrolled/") }
      end
    end
  end
end
