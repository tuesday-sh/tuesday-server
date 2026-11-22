# frozen_string_literal: true

require "test_helper"

module Api
  module V1
    class NotificationEngineTest < ActionDispatch::IntegrationTest
      setup do
        @headers = {
          "X-Tuesday-Owner-Key" => "test-engine-owner",
          "X-Tuesday-Device-ID" => "test-workbench-01"
        }
      end

      test "lists all declarative YAML notification rules" do
        get "/api/v1/notifications/rules", headers: @headers
        assert_response :success
        body = JSON.parse(response.body)
        assert_equal "ok", body["status"]
        assert body["count"] >= 6
        rule_ids = body["rules"].map { |r| r["id"] }
        assert_includes rule_ids, "gold_critical_cve"
        assert_includes rule_ids, "maintenance_backup_check"
        assert_includes rule_ids, "device_unclassified_review"
        assert_includes rule_ids, "onboarding_first_device"
        assert_includes rule_ids, "admin_broadcast"
      end

      test "test_rule emits canonical notification and feed filters by surface" do
        post "/api/v1/notifications/test_rule",
             params: { rule_id: "gold_critical_cve", dry_run: false, force: true },
             headers: @headers,
             as: :json
        assert_response :success
        created = JSON.parse(response.body)
        assert_equal "created", created["action"]
        assert_equal %w[push bulletin], created["notification"]["surfaces"]
        assert_equal "pending", created["notification"]["pushStatus"]

        get "/api/v1/notifications/feed", params: { surface: "bulletin" }, headers: @headers
        assert_response :success
        feed = JSON.parse(response.body)
        assert_equal 1, feed["count"]
        assert_equal "gold_critical_cve", feed["notifications"].first["ruleId"]

        get "/api/v1/notifications/feed", params: { surface: "reminder" }, headers: @headers
        assert_response :success
        reminder_feed = JSON.parse(response.body)
        assert_equal 0, reminder_feed["count"]
      end

      test "shared lifecycle: push_seen does not dismiss in-app item, dismissed resolves it" do
        post "/api/v1/notifications/test_rule",
             params: { rule_id: "maintenance_backup_check", force: true },
             headers: @headers,
             as: :json
        assert_response :success
        notif_id = JSON.parse(response.body).dig("notification", "id")

        # Swiping OS push only updates pushStatus
        patch "/api/v1/notifications/#{notif_id}",
              params: { action_type: "push_seen" },
              headers: @headers,
              as: :json
        assert_response :success
        after_push = JSON.parse(response.body)["notification"]
        assert_equal "push_seen", after_push["pushStatus"]
        assert_equal "active", after_push["status"]

        # Snooze
        patch "/api/v1/notifications/#{notif_id}",
              params: { action_type: "snoozed", snooze_minutes: 120 },
              headers: @headers,
              as: :json
        assert_response :success
        assert_equal "snoozed", JSON.parse(response.body).dig("notification", "status")

        # Dismiss resolves across surfaces
        patch "/api/v1/notifications/#{notif_id}",
              params: { action_type: "dismissed" },
              headers: @headers,
              as: :json
        assert_response :success
        assert_equal "dismissed", JSON.parse(response.body).dig("notification", "status")
      end

      test "sweep_runner records audit run and wakes elapsed snoozed notifications" do
        post "/api/v1/notifications/test_rule",
             params: { rule_id: "maintenance_backup_check", force: true },
             headers: @headers,
             as: :json
        assert_response :success
        notif_id = JSON.parse(response.body).dig("notification", "id")

        SiteNotification.where(id: notif_id).update_all(status: "snoozed", snoozed_until: 5.minutes.ago)

        result = Notifications::SweepRunner.run!(trigger_source: "test_suite")
        assert_equal 1, result[:wokenSnoozed]
        assert_equal "active", SiteNotification.find(notif_id).status

        run = NotificationJobRun.find(result[:jobRunId])
        assert_equal "succeeded", run.status
        assert_equal "test_suite", run.trigger_source
        assert_equal 1, run.woken_snoozed
      end

      test "exposes server version from /api/v1/version and /api/up" do
        get "/api/v1/version"
        assert_response :success
        v = JSON.parse(response.body)
        assert_equal "ok", v["status"]
        assert v["version"].present?
        assert_equal "test", v["railsEnv"]

        get "/api/up"
        assert_response :success
        up = JSON.parse(response.body)
        assert_equal true, up["is_up"]
        assert_equal v["version"], up["version"]
      end

      test "push_dispatcher skips cleanly when credentials are unconfigured and generates valid APNs ES256 JWT" do
        post "/api/v1/notifications/test_rule",
             params: { rule_id: "gold_critical_cve", force: true },
             headers: @headers,
             as: :json
        assert_response :success
        notif = SiteNotification.find(JSON.parse(response.body).dig("notification", "id"))

        DevicePushToken.create!(
          network_site_id: notif.network_site_id,
          client_device_id: "test-ios-01",
          platform: "ios",
          app_flavor: "tuesday",
          fcm_token: "apns-device-token-abc123",
          critical_enabled: true,
          digest_enabled: true
        )

        res = Notifications::PushDispatcher.dispatch_notification!(notif)
        assert_equal "skipped_unconfigured", res[:outcome]
        assert_equal "pending", notif.reload.push_status

        ec_key = OpenSSL::PKey::EC.generate("prime256v1")
        jwt = Notifications::PushDispatcher.build_apns_jwt(
          key_id: "KEY1234567",
          team_id: "TEAM123456",
          private_key_pem: ec_key.to_pem
        )
        assert_equal 3, jwt.split(".").size
      end

      test "discord notifier formats activation payload and ignores synthetic device IDs" do
        assert Telemetry::DiscordNotifier.ignored_device?("test-workbench-01")
        assert Telemetry::DiscordNotifier.ignored_device?("anonymous")
        refute Telemetry::DiscordNotifier.ignored_device?("pixel9-real-user-uuid")

        ev = ProductTelemetryEvent.new(
          event_name: "app.activated",
          event_domain: "client",
          client_platform: "android",
          app_flavor: "tuesday",
          device_id: "pixel9-real-user-uuid"
        )
        payload = Telemetry::DiscordNotifier.build_activation_payload(ev)
        assert_equal "Tuesday Activation Bot", payload[:username]
        assert_equal "New User Activation", payload[:embeds].first[:title]
        assert_equal :unconfigured, Telemetry::DiscordNotifier.notify_first_activation!(ev)
      end

      test "enforces max_lifetime_sends and detects 2nd Tuesday Patch Tuesday window" do
        site = NetworkSite.create!(owner_key: "cap-test-owner", name: "Cap Lab", slug: "cap-lab")
        first = Notifications::Engine.emit_for_rule!(site: site, rule_id: "onboarding_core_gear", dedup_key: "core:1")
        assert_equal "created", first[:action]

        second = Notifications::Engine.emit_for_rule!(site: site, rule_id: "onboarding_core_gear", dedup_key: "core:2")
        assert_equal "capped", second[:action]

        # Nov 10, 2026 is the 2nd Tuesday of November
        pt_second_tue = Time.find_zone("America/Los_Angeles").local(2026, 11, 10, 10, 15, 0)
        pt_first_tue = Time.find_zone("America/Los_Angeles").local(2026, 11, 3, 10, 15, 0)
        assert Notifications::Engine.patch_tuesday_window?(pt_second_tue)
        refute Notifications::Engine.patch_tuesday_window?(pt_first_tue)
      end
    end
  end
end
