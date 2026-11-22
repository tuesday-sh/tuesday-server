# frozen_string_literal: true

module Api
  module V1
    class NotificationsController < ApplicationController
      include Api::V1::SiteScoping
      skip_before_action :verify_authenticity_token, raise: false

      # POST /api/v1/notifications/register_token
      # Registers or updates a client device's push notification preferences and optional FCM registration token.
      def register_token
        site = current_network_site(auto_create: true)
        client_id = resolve_client_device_id
        flavor = (params[:app_flavor].presence || "tuesday").to_s.downcase
        flavor = "surethingnet" if flavor == "surething"

        record = DevicePushToken.find_or_initialize_by(
          network_site_id: site.id,
          client_device_id: client_id
        )
        record.assign_attributes(
          platform: (params[:platform].presence || request.headers["X-Tuesday-Client-Platform"].presence || "android").to_s.downcase,
          app_flavor: %w[tuesday surethingnet].include?(flavor) ? flavor : "tuesday",
          fcm_token: params[:fcm_token].presence || record.fcm_token,
          critical_enabled: params.key?(:critical_enabled) ? ActiveModel::Type::Boolean.new.cast(params[:critical_enabled]) : true,
          digest_enabled: params.key?(:digest_enabled) ? ActiveModel::Type::Boolean.new.cast(params[:digest_enabled]) : true,
          last_seen_at: Time.current
        )
        record.save!

        render json: {
          status: "registered",
          clientDeviceId: record.client_device_id,
          networkSiteId: site.id,
          appFlavor: record.app_flavor,
          criticalEnabled: record.critical_enabled,
          digestEnabled: record.digest_enabled,
          fcmTokenPresent: record.fcm_token.present?
        }
      end

      # POST /api/v1/notifications/dispatch
      # Evaluates the caller's enrolled inventory against the Gold Data Lake and queues push notifications.
      def dispatch_notifications
        site = current_network_site(auto_create: true)
        client_id = resolve_client_device_id
        flavor = (params[:app_flavor].presence || "tuesday").to_s.downcase
        flavor = "surethingnet" if flavor == "surething"
        force_resend = ActiveModel::Type::Boolean.new.cast(params[:force_resend]) || false
        all_sites = ActiveModel::Type::Boolean.new.cast(params[:all_sites]) || false

        sites_to_dispatch = if all_sites
                              NetworkSite.joins(:monitored_devices).distinct.to_a.presence || [site]
                            elsif site.monitored_devices.any?
                              [site]
                            else
                              [NetworkSite.joins(:monitored_devices).group("network_sites.id").order("COUNT(monitored_devices.id) DESC").first || site]
                            end

        total_queued = 0
        total_skipped = 0
        all_deliveries = []
        seen_bulletins = Set.new

        sites_to_dispatch.each do |target_site|
          result = Notifications::FleetBulletinDispatcher.dispatch_for_site!(
            target_site,
            client_device_id: client_id,
            app_flavor: flavor,
            force_resend: force_resend
          )
          total_queued += result[:queued_count]
          total_skipped += result[:skipped_existing_count]
          result[:deliveries].each do |d|
            next if seen_bulletins.include?(d[:bulletinExternalId])

            seen_bulletins.add(d[:bulletinExternalId])
            all_deliveries << d
          end
        end

        render json: {
          status: "dispatched",
          networkSiteId: sites_to_dispatch.first.id,
          clientDeviceId: client_id,
          monitoredDevicesCount: sites_to_dispatch.sum { |s| s.monitored_devices.count },
          queuedCount: total_queued,
          skippedExistingCount: total_skipped,
          notifications: all_deliveries
        }
      end

      # GET /api/v1/notifications/pending
      # Returns pending (undelivered) notifications for the connected Android/iOS client and marks them `delivered_pull`
      # when `mark_delivered=true` (default true).
      def pending
        client_id = resolve_client_device_id
        auto_dispatch = ActiveModel::Type::Boolean.new.cast(params.fetch(:auto_dispatch, true))
        mark_delivered = ActiveModel::Type::Boolean.new.cast(params.fetch(:mark_delivered, true))

        if auto_dispatch
          all_sites = ActiveModel::Type::Boolean.new.cast(params[:all_sites]) || false
          owner_scope = NetworkSite.where(owner_key: current_owner_key)
          site = current_network_site(auto_create: false)
          sites_to_dispatch = if all_sites
                                owner_scope.joins(:monitored_devices).distinct.to_a
                              elsif site && site.monitored_devices.any?
                                [site]
                              else
                                []
                              end
          sites_to_dispatch.each do |target_site|
            Notifications::FleetBulletinDispatcher.dispatch_for_site!(
              target_site,
              client_device_id: client_id,
              app_flavor: (params[:app_flavor].presence || "tuesday").to_s
            )
          end
        end

        scope = NotificationDelivery.includes(:monitored_device)
                                    .where(client_device_id: client_id, delivery_status: %w[pending sent_fcm])
                                    .order(is_high_sev: :desc, created_at: :desc)

        seen_ext_ids = Set.new
        deduped_records = scope.to_a.select do |rec|
          if seen_ext_ids.include?(rec.bulletin_external_id)
            false
          else
            seen_ext_ids.add(rec.bulletin_external_id)
            true
          end
        end
        items = deduped_records.map(&:to_api_hash)

        if mark_delivered && scope.any?
          now = Time.current
          scope.update_all(delivery_status: "delivered_pull", delivered_at: now, updated_at: now)
          emit_notification_telemetry(
            event_name: "notification.delivered",
            client_id: client_id,
            properties: {
              count: items.size,
              bulletinExternalIds: items.map { |i| i[:bulletinExternalId] }
            }
          )
        end

        render json: {
          status: "ok",
          clientDeviceId: client_id,
          count: items.size,
          notifications: items
        }
      end

      # POST /api/v1/notifications/:id/ack
      # Records when the user taps (`status: "opened"`) or dismisses (`status: "dismissed"`) a push notification.
      def ack
        delivery = NotificationDelivery.find_by(id: params[:id]) ||
                   NotificationDelivery.find_by(
                     client_device_id: resolve_client_device_id,
                     bulletin_external_id: params[:id].to_s
                   )

        return render json: { error: "Notification delivery not found" }, status: :not_found if delivery.nil?

        new_status = params[:action_type].to_s == "dismissed" ? "dismissed" : "opened"
        now = Time.current
        attrs = { delivery_status: new_status, updated_at: now }
        attrs[:opened_at] = now if new_status == "opened"
        delivery.update!(attrs)

        emit_notification_telemetry(
          event_name: "notification.#{new_status}",
          client_id: delivery.client_device_id,
          site_id: delivery.network_site_id,
          target_id: delivery.bulletin_external_id,
          properties: {
            bulletinExternalId: delivery.bulletin_external_id,
            deliveryChannel: delivery.delivery_channel,
            isHighSev: delivery.is_high_sev,
            matchedByGuess: delivery.matched_by_guess,
            brokeThroughMute: delivery.broke_through_mute,
            deepLinkUri: delivery.deep_link_uri
          }
        )

        render json: {
          status: "acknowledged",
          notification: delivery.to_api_hash
        }
      end

      # GET /api/v1/notifications/rules
      # Returns all declarative notification rules from config/notification_rules.yml.
      def rules
        render json: {
          status: "ok",
          count: Notifications::RuleRegistry.all.size,
          rules: Notifications::RuleRegistry.all
        }
      end

      # GET /api/v1/notifications/feed
      # Canonical delta-sync feed for OS push, Bulletins, and Reminders.
      def feed
        site = current_network_site(auto_create: true)
        since = params[:since].present? ? Time.zone.parse(params[:since].to_s) : nil
        surface_filter = params[:surface].presence&.to_s
        status_filter = params[:status].presence&.to_s || "unresolved"

        scope = SiteNotification.includes(:monitored_device)
                                .where(network_site_id: site.id)
                                .updated_since(since)
                                .order(created_at: :desc)

        scope = scope.unresolved if status_filter == "unresolved"
        scope = scope.where(status: status_filter) if SiteNotification::VALID_STATUSES.include?(status_filter)

        records = scope.to_a
        records = records.select { |r| r.targets_surface?(surface_filter) } if surface_filter.present?

        other_sites = NetworkSite.where(owner_key: current_owner_key).where.not(id: site.id).to_a
        other_site_ids = other_sites.map(&:id)
        other_sites_by_id = other_sites.index_by(&:id)

        other_unresolved = if other_site_ids.any?
                             SiteNotification.unresolved.where(network_site_id: other_site_ids).to_a
                           else
                             []
                           end

        other_sites_summary = other_sites.map do |os|
          os_notifs = other_unresolved.select { |n| n.network_site_id == os.id }
          {
            networkSiteId: os.id,
            name: os.name,
            unresolvedCount: os_notifs.size,
            criticalCount: os_notifs.count { |n| %w[critical high].include?(n.priority) }
          }
        end

        serialized = records.map do |rec|
          hash = rec.to_api_hash
          ext_id = rec.payload["external_id"].presence
          also_sites = if other_unresolved.any?
                         other_unresolved.select do |other|
                           other.rule_id == rec.rule_id &&
                             (ext_id.blank? || other.payload["external_id"] == ext_id)
                         end.map(&:network_site_id).uniq.filter_map do |sid|
                           os = other_sites_by_id[sid]
                           os ? { networkSiteId: os.id, name: os.name } : nil
                         end
                       else
                         []
                       end
          hash.merge(alsoAffectedSites: also_sites)
        end

        render json: {
          status: "ok",
          networkSiteId: site.id,
          networkSiteName: site.name,
          syncedAt: Time.current.utc.iso8601,
          count: serialized.size,
          otherSitesSummary: other_sites_summary,
          notifications: serialized
        }
      end

      # PATCH /api/v1/notifications/:id
      # Transitions a SiteNotification through the shared lifecycle (seen, snoozed, completed, dismissed, push_seen, reopen).
      def update_state
        site = current_network_site(auto_create: false)
        record = SiteNotification.find_by(id: params[:id], network_site_id: site&.id) ||
                 SiteNotification.find_by(id: params[:id])
        return render json: { error: "Notification not found" }, status: :not_found if record.nil?

        action = params[:action_type].presence || params[:status].presence
        return render json: { error: "Missing action_type or status" }, status: :unprocessable_entity if action.blank?

        record.transition!(action, snooze_minutes: params[:snooze_minutes])
        render json: {
          status: "ok",
          notification: record.to_api_hash
        }
      rescue ArgumentError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/notifications/test_rule
      # Evaluates or previews a specific declarative rule_id (for Web Workbench rule testing).
      def test_rule
        site = current_network_site(auto_create: true)
        rule_id = params[:rule_id].to_s
        dry_run = ActiveModel::Type::Boolean.new.cast(params.fetch(:dry_run, false))
        force = ActiveModel::Type::Boolean.new.cast(params.fetch(:force, true))
        context = params[:context].is_a?(ActionController::Parameters) ? params[:context].to_unsafe_h : (params[:context] || {})
        surfaces = params[:surfaces].present? ? Array(params[:surfaces]) : nil

        result = Notifications::Engine.emit_for_rule!(
          site: site,
          rule_id: rule_id,
          context: context,
          surfaces_override: surfaces,
          dedup_key: params[:dedup_key].presence,
          dry_run: dry_run,
          force: force
        )

        render json: {
          status: "ok",
          action: result[:action],
          notification: result[:notification]
        }
      rescue ArgumentError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/notifications/broadcast
      # Issues a manual/admin broadcast notification.
      def broadcast
        site = current_network_site(auto_create: true)
        result = Notifications::Engine.emit_for_rule!(
          site: site,
          rule_id: "admin_broadcast",
          context: {
            "title" => params[:title].presence || "System Broadcast",
            "body" => params[:body].presence || "Operational notice from Tuesday."
          },
          surfaces_override: params[:surfaces].present? ? Array(params[:surfaces]) : nil,
          dedup_key: params[:dedup_key].presence || "admin_broadcast:#{Time.current.to_i}",
          force: true
        )

        render json: {
          status: "ok",
          action: result[:action],
          notification: result[:notification]
        }
      end

      private

      def resolve_client_device_id
        (request.headers["X-Tuesday-Device-ID"].presence ||
          params[:client_device_id].presence ||
          params[:device_id].presence ||
          "android-default").to_s.strip
      end

      def emit_notification_telemetry(event_name:, client_id:, site_id: nil, target_id: nil, properties: {})
        return unless defined?(ProductTelemetryEvent) && ProductTelemetryEvent.table_exists?

        ev = ProductTelemetryEvent.create!(
          event_name: event_name,
          event_domain: "notifications",
          network_site_id: site_id,
          client_platform: (request.headers["X-Tuesday-Client-Platform"].presence || "android").to_s.downcase,
          device_id: client_id,
          target_entity_type: "CuratedBulletin",
          target_entity_id: target_id,
          properties: properties
        )
        Telemetry::HostedAiLogger.log_product_event(ev.to_telemetry_hash)
      rescue StandardError => e
        Rails.logger.warn("[Api::V1::NotificationsController] Telemetry emit skipped: #{e.message}")
      end
    end
  end
end
