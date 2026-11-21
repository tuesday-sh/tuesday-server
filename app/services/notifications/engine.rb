# frozen_string_literal: true

module Notifications
  class Engine
    class << self
      # Evaluates a single rule for a site and emits (or previews) a canonical SiteNotification.
      def emit_for_rule!(site:, rule_id:, context: {}, monitored_device: nil, surfaces_override: nil, dedup_key: nil, dry_run: false, force: false)
        rule = RuleRegistry.find(rule_id)
        raise ArgumentError, "Unknown notification rule: #{rule_id}" if rule.nil?

        merged_ctx = build_context(site, rule, context, monitored_device)
        computed_dedup = dedup_key.presence || "#{rule['id']}:#{site.id}:#{monitored_device&.id || 'site'}"
        merged_ctx["dedup_key"] = computed_dedup

        target_surfaces = Array(surfaces_override.presence || rule["surfaces"]).map(&:to_s)
        title = interpolate(rule["title_template"], merged_ctx)
        body = interpolate(rule["body_template"], merged_ctx)
        deep_link = interpolate(rule["deep_link_template"].to_s, merged_ctx)
        expires_at = rule["ttl_hours"].to_i.positive? ? Time.current + rule["ttl_hours"].to_i.hours : nil
        push_status = target_surfaces.include?("push") ? "pending" : "none"

        attrs = {
          network_site: site,
          monitored_device: monitored_device,
          rule_id: rule["id"],
          trigger_type: rule["trigger_type"],
          dedup_key: computed_dedup,
          priority: rule["priority"] || "normal",
          status: "active",
          push_status: push_status,
          title: title,
          body: body,
          cta_label: rule["cta_label"],
          deep_link_uri: deep_link,
          expires_at: expires_at
        }

        if dry_run
          preview = SiteNotification.new(attrs)
          preview.surfaces = target_surfaces
          preview.payload = merged_ctx
          return { action: "preview", notification: preview.to_api_hash }
        end

        existing = SiteNotification.find_by(network_site_id: site.id, dedup_key: computed_dedup)
        if existing && !force
          return { action: "deduped", notification: existing.to_api_hash }
        end

        record = existing || SiteNotification.new(network_site: site, dedup_key: computed_dedup)
        record.assign_attributes(attrs.except(:network_site, :dedup_key))
        record.surfaces = target_surfaces
        record.payload = merged_ctx
        record.snoozed_until = nil
        record.resolved_at = nil
        record.save!

        { action: existing ? "updated" : "created", notification: record.to_api_hash }
      end

      # Sweeps a site against enabled rules (e.g., onboarding, unclassified devices, maintenance).
      def evaluate_site!(site)
        results = []

        if site.monitored_devices.empty?
          results << emit_for_rule!(site: site, rule_id: "onboarding_first_device")
        else
          site.monitored_devices.where.not(confidence_tier: "confirmed").find_each do |device|
            results << emit_for_rule!(
              site: site,
              rule_id: "device_unclassified_review",
              monitored_device: device,
              context: {
                "device_label" => device.short_label || device.name,
                "room_location" => device.room_location || "Network",
                "device_id" => device.external_uuid
              }
            )
          end
        end

        results
      end

      private

      def build_context(site, rule, overrides, monitored_device)
        base = (rule["sample_context"] || {}).transform_keys(&:to_s)
        base["site_name"] = site.name if site&.name.present?
        if monitored_device
          base["device_label"] = monitored_device.short_label || monitored_device.name
          base["device_id"] = monitored_device.external_uuid
          base["room_location"] = monitored_device.room_location if monitored_device.room_location.present?
        end
        base.merge((overrides || {}).transform_keys(&:to_s))
      end

      def interpolate(template, ctx)
        template.to_s.gsub(/\{\{(\w+)\}\}/) { |match| ctx.fetch(Regexp.last_match(1), match).to_s }
      end
    end
  end
end
