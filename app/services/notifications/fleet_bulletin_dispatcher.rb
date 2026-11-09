# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Notifications
  # Evaluates a NetworkSite's enrolled MonitoredDevice inventory against the Gold Data Lake
  # via `Bulletins::GoldSnapshotLoader` / `Bulletins::InboxAssembler` and queues idempotent,
  # confidence-tier-aware push notifications (`NotificationDelivery`) for Android/iOS clients.
  #
  # Invariants:
  # 1. Zero LLM Turns (0 tokens): Uses pre-refined Gold playbooks from Track 2.
  # 2. Confidence-Tier Guardrail:
  #    - `:confirmed` devices receive High-Sev (`tuesday_critical_bulletins`) + Unmuted Routine (`tuesday_lifecycle_digests`).
  #    - `:provisional_guess` devices NEVER receive routine release notifications; only High-Sev family advisories
  #      are queued (`matched_by_guess: true`) with explicit model-sticker verification guidance.
  #    - `:opaque_unknown` devices receive 0 notifications.
  # 3. Mute Breakthrough: Muted feeds suppress routine releases; only `is_high_sev: true` breaks through (`broke_through_mute: true`).
  # 4. Idempotent Deduplication: Keyed by `[network_site_id, client_device_id, bulletin_external_id]`.
  class FleetBulletinDispatcher
    CRITICAL_CHANNEL = "tuesday_critical_bulletins"
    DIGEST_CHANNEL   = "tuesday_lifecycle_digests"

    class << self
      def dispatch_for_all_sites!(force_resend: false)
        return { sites_evaluated: 0, notifications_queued: 0 } unless defined?(::NetworkSite) && ::NetworkSite.table_exists?

        total_sites = 0
        total_queued = 0
        deliveries = []

        ::NetworkSite.includes(:monitored_devices).find_each do |site|
          next if site.monitored_devices.none?

          total_sites += 1
          res = dispatch_for_site!(site, force_resend: force_resend)
          total_queued += res[:queued_count]
          deliveries.concat(res[:deliveries])
        end

        {
          sites_evaluated: total_sites,
          notifications_queued: total_queued,
          deliveries: deliveries
        }
      end

      def dispatch_for_site!(site, client_device_id: nil, app_flavor: nil, force_resend: false)
        return { queued_count: 0, skipped_existing_count: 0, deliveries: [] } if site.nil? || site.monitored_devices.none?

        # Normalize any legacy enrolled PURLs (`pkg:generic/enrolled/...`) before matching
        ensure_canonical_device_purls!(site)

        target_clients = resolve_target_clients(site, override_client_id: client_device_id, override_flavor: app_flavor)
        raw_bulletins_by_id = Bulletins::GoldSnapshotLoader.load_gold_bulletins.index_by(&:external_id)
        tracked_hashes = site.monitored_devices.reload.map(&:to_gold_hash)

        queued = []
        skipped_existing = 0

        target_clients.each do |client_target|
          cid = client_target[:client_device_id]
          flavor = client_target[:app_flavor]
          critical_on = client_target[:critical_enabled]
          digest_on = client_target[:digest_enabled]

          assembled = Bulletins::GoldSnapshotLoader.assemble_bulletins_from_gold(
            app_flavor: flavor,
            muted_feed_slugs: site.muted_feed_slugs_list,
            tracked_devices: tracked_hashes
          )

          Array(assembled[:inbox]).each do |inbox_item|
            ext_id = inbox_item[:external_id].to_s
            is_high = !!inbox_item[:is_high_sev]
            next if is_high && !critical_on
            next if !is_high && !digest_on

            existing = ::NotificationDelivery.find_by(
              network_site_id: site.id,
              client_device_id: cid,
              bulletin_external_id: ext_id
            )

            if existing && !force_resend
              skipped_existing += 1
              next
            end

            raw_bulletin = raw_bulletins_by_id[ext_id]
            matched_dev = find_matching_monitored_device(site.monitored_devices, raw_bulletin&.purl_base, inbox_item[:feed_slug])

            channel = is_high ? CRITICAL_CHANNEL : DIGEST_CHANNEL
            title, body = format_notification_copy(inbox_item, matched_dev, flavor: flavor)
            deep_link = "tuesday://bulletins/#{ext_id}"
            dev_deep_link = matched_dev ? "tuesday://device/#{matched_dev.external_uuid}" : "tuesday://status"

            now = Time.current
            delivery = existing || ::NotificationDelivery.new(
              network_site_id: site.id,
              client_device_id: cid,
              bulletin_external_id: ext_id
            )

            delivery.assign_attributes(
              monitored_device_id: matched_dev&.id,
              feed_slug: inbox_item[:feed_slug],
              bulletin_type: inbox_item[:bulletin_type].to_s,
              is_high_sev: is_high,
              broke_through_mute: !!inbox_item[:broke_through_mute],
              matched_by_guess: !!inbox_item[:matched_by_guess],
              delivery_channel: channel,
              delivery_status: "pending",
              title: title,
              body: body,
              deep_link_uri: deep_link,
              device_deep_link_uri: dev_deep_link,
              payload_json: JSON.generate(
                bulletin_external_id: ext_id,
                feed_slug: inbox_item[:feed_slug],
                bulletin_type: inbox_item[:bulletin_type],
                is_high_sev: is_high,
                broke_through_mute: !!inbox_item[:broke_through_mute],
                matched_by_guess: !!inbox_item[:matched_by_guess],
                candidate_models: Array(inbox_item[:candidate_models]),
                monitored_device_id: matched_dev&.external_uuid,
                monitored_device_label: matched_dev&.short_label || matched_dev&.name,
                category_code: matched_dev&.category_code,
                deep_link_uri: deep_link,
                device_deep_link_uri: dev_deep_link
              ),
              sent_at: now
            )
            delivery.save!

            if client_target[:fcm_token].present? && ENV["FCM_ENABLED"] == "true"
              send_fcm_http_v1(client_target[:fcm_token], delivery)
            end

            queued << delivery.to_api_hash
          end
        end

        {
          queued_count: queued.size,
          skipped_existing_count: skipped_existing,
          deliveries: queued
        }
      end

      private

      def ensure_canonical_device_purls!(site)
        site.monitored_devices.each do |dev|
          current = dev.purls_list
          needs_fix = current.empty? ||
                      current.any? { |p| p.start_with?("pkg:generic/enrolled/", "pkg:generic/ubiquiti-inc/", "pkg:generic/espressif-nodemcu/", "pkg:generic/ai-thinker-nodemcu/") } ||
                      (dev.model_number.to_s.include?("+") && current.none? { |p| p.include?("-plus") }) ||
                      (dev.model_number.to_s.include?("/") && current.size < 2)
          next unless needs_fix

          resolved = Discovery::HardwareVisionService.resolve_gold_device_identity(
            vendor: dev.vendor,
            model: dev.model_number,
            version: dev.version
          )
          dev.purls_list = resolved[:purls]
          dev.category_code = resolved[:category_code] if resolved[:category_code].present?
          dev.save
        end
      rescue StandardError => e
        Rails.logger.warn("[Notifications::FleetBulletinDispatcher] PURL normalization skipped: #{e.message}")
      end

      def resolve_target_clients(site, override_client_id: nil, override_flavor: nil)
        tokens = if defined?(::DevicePushToken) && ::DevicePushToken.table_exists?
                   ::DevicePushToken.where(network_site_id: site.id).to_a
                 else
                   []
                 end

        if override_client_id.present?
          tok = tokens.find { |t| t.client_device_id == override_client_id }
          return [
            {
              client_device_id: override_client_id,
              app_flavor: override_flavor.presence || tok&.app_flavor || "tuesday",
              fcm_token: tok&.fcm_token,
              critical_enabled: tok ? tok.critical_enabled : true,
              digest_enabled: tok ? tok.digest_enabled : true
            }
          ]
        end

        if tokens.any?
          tokens.map do |tok|
            {
              client_device_id: tok.client_device_id,
              app_flavor: override_flavor.presence || tok.app_flavor.presence || "tuesday",
              fcm_token: tok.fcm_token,
              critical_enabled: tok.critical_enabled,
              digest_enabled: tok.digest_enabled
            }
          end
        else
          inferred_cid = site.owner_key.to_s.sub(/\Adevice:/, "").presence || "default-client"
          [
            {
              client_device_id: inferred_cid,
              app_flavor: override_flavor.presence || "tuesday",
              fcm_token: nil,
              critical_enabled: true,
              digest_enabled: true
            }
          ]
        end
      end

      def find_matching_monitored_device(devices, bulletin_purl_base, feed_slug)
        clean_bp = bulletin_purl_base.to_s.downcase.split("@").first.to_s
        if clean_bp.present?
          exact = devices.find do |dev|
            dev.purls_list.any? do |dp|
              clean_dp = dp.to_s.downcase.split("@").first.sub(/\/\*$/, "")
              clean_dp == clean_bp || clean_dp.start_with?("#{clean_bp}/") || clean_bp.start_with?("#{clean_dp}/")
            end
          end
          return exact if exact
        end

        devices.first
      end

      def format_notification_copy(inbox_item, matched_dev, flavor: "tuesday")
        raw_title = inbox_item[:title].to_s
        raw_body = inbox_item[:body].to_s
        dev_label = matched_dev&.short_label.presence || matched_dev&.name.presence || "enrolled hardware"

        if inbox_item[:matched_by_guess]
          title = "⚠ Verify Model Guess: #{raw_title}"
          body = "#{raw_body} (Matched provisional guess #{dev_label} — check the model sticker before acting.)"
          [title, body]
        elsif inbox_item[:broke_through_mute]
          title = "[Critical Override] #{raw_title}"
          [title, raw_body]
        else
          [raw_title, raw_body]
        end
      end

      def send_fcm_http_v1(fcm_token, delivery)
        project_id = ENV.fetch("GCP_PROJECT_ID", "tuesday-sh")
        access_token = ENV["FCM_ACCESS_TOKEN"].to_s.strip
        return false if access_token.empty?

        uri = URI.parse("https://fcm.googleapis.com/v1/projects/#{project_id}/messages:send")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 5
        http.read_timeout = 8

        req = Net::HTTP::Post.new(uri.request_uri)
        req["Authorization"] = "Bearer #{access_token}"
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(
          message: {
            token: fcm_token,
            notification: {
              title: delivery.title,
              body: delivery.body
            },
            data: {
              delivery_id: delivery.id.to_s,
              bulletin_external_id: delivery.bulletin_external_id,
              deep_link_uri: delivery.deep_link_uri,
              device_deep_link_uri: delivery.device_deep_link_uri.to_s,
              delivery_channel: delivery.delivery_channel
            },
            android: {
              priority: delivery.is_high_sev ? "HIGH" : "NORMAL",
              notification: {
                channel_id: delivery.delivery_channel,
                click_action: "android.intent.action.VIEW"
              }
            }
          }
        )

        resp = http.request(req)
        if resp.code.to_i.between?(200, 299)
          delivery.update_columns(delivery_status: "sent_fcm", updated_at: Time.current)
          true
        else
          false
        end
      rescue StandardError => e
        Rails.logger.warn("[Notifications::FleetBulletinDispatcher] FCM send failed: #{e.message}")
        false
      end
    end
  end
end
