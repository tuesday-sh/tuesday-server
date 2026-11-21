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
    end
  end
end
