# frozen_string_literal: true

require "test_helper"

module Api
  module V1
    class NotificationsControllerTest < ActionDispatch::IntegrationTest
      setup do
        NotificationDelivery.delete_all
        DevicePushToken.delete_all
        MonitoredDevice.delete_all
        NetworkSite.delete_all
        CanonicalFeed.delete_all
        CuratedBulletin.delete_all

        @headers = {
          "X-Tuesday-Device-ID" => "pixel9-field-test",
          "X-Tuesday-Client-Platform" => "android"
        }

        # Enroll real hardware from the Pixel 9 field test:
        # 1. Confirmed Cisco WS-C2960-8TC-L (C4 Core Switch -> High-Sev EOL bulletin)
        post "/api/v1/discovery/confirm", params: {
          session_id: "sess-cisco",
          resolution_status: "confirmed_candidate",
          confirmed_vendor: "Cisco",
          confirmed_model: "WS-C2960-8TC-L"
        }, headers: @headers, as: :json
        assert_response :success

        # 2. Provisional Guess Synology DS220+ (C6 NAS -> High-Sev CVE allowed, Routine release suppressed)
        post "/api/v1/discovery/confirm", params: {
          session_id: "sess-synology",
          resolution_status: "saved_best_guess",
          confirmed_vendor: "Synology",
          confirmed_model: "DS220+"
        }, headers: @headers, as: :json
        assert_response :success

        # 3. Confirmed SONOFF ZBDongle-E (C8 Zigbee -> Routine release on unmuted feed)
        post "/api/v1/discovery/confirm", params: {
          session_id: "sess-sonoff",
          resolution_status: "confirmed_candidate",
          confirmed_vendor: "SONOFF",
          confirmed_model: "ZBDongle-E"
        }, headers: @headers, as: :json
        assert_response :success

        # 4. Confirmed Espressif / NodeMCU ESP8266MOD (C8 DIY Board -> High-Sev CVE on muted lg-esphome-iot feed)
        post "/api/v1/discovery/confirm", params: {
          session_id: "sess-esp8266",
          resolution_status: "confirmed_candidate",
          confirmed_vendor: "Espressif / NodeMCU",
          confirmed_model: "ESP8266MOD"
        }, headers: @headers, as: :json
        assert_response :success
      end

      test "dispatches confidence-tier-aware notifications, suppresses routine guess updates, and deduplicates" do
        post "/api/v1/notifications/register_token", params: {
          platform: "android",
          app_flavor: "tuesday",
          fcm_token: "fcm_test_token_pixel9",
          critical_enabled: true,
          digest_enabled: true
        }, headers: @headers, as: :json
        assert_response :success

        post "/api/v1/notifications/dispatch", params: { app_flavor: "tuesday" }, headers: @headers, as: :json
        assert_response :success
        dispatch_body = JSON.parse(response.body)

        notifs = dispatch_body["notifications"]
        ext_ids = notifs.map { |n| n["bulletinExternalId"] }

        # 1. Cisco WS-C2960-8TC-L High-Sev EOL queued on critical channel
        assert_includes ext_ids, "EOL-cisco-ws-c2960-8tc-l"
        cisco_notif = notifs.find { |n| n["bulletinExternalId"] == "EOL-cisco-ws-c2960-8tc-l" }
        assert_equal "tuesday_critical_bulletins", cisco_notif["deliveryChannel"]
        assert_equal "tuesday://bulletins/EOL-cisco-ws-c2960-8tc-l", cisco_notif["deepLinkUri"]
        assert_equal "C4", cisco_notif["categoryCode"]

        # 2. Provisional Guess Synology DS220+ High-Sev CVE queued with matchedByGuess warning,
        #    while routine DSM 7.2.2 Update 2 is SUPPRESSED
        assert_includes ext_ids, "CVE-2024-10443-synology-ds220-plus"
        refute_includes ext_ids, "REL-synology-dsm-7.2.2-routine"
        syn_notif = notifs.find { |n| n["bulletinExternalId"] == "CVE-2024-10443-synology-ds220-plus" }
        assert_equal true, syn_notif["matchedByGuess"]
        assert_match(/Verify Model Guess/, syn_notif["title"])
        assert_equal "C6", syn_notif["categoryCode"]

        # 3. Confirmed SONOFF ZBDongle-E routine release queued on digest channel
        assert_includes ext_ids, "REL-sonoff-zbdongle-e-7.4.4"
        sonoff_notif = notifs.find { |n| n["bulletinExternalId"] == "REL-sonoff-zbdongle-e-7.4.4" }
        assert_equal "tuesday_lifecycle_digests", sonoff_notif["deliveryChannel"]

        # 4. Confirmed ESP8266MOD High-Sev CVE on muted feed breaks through mute
        assert_includes ext_ids, "CVE-2026-39104-esp8266-sdk"
        esp_notif = notifs.find { |n| n["bulletinExternalId"] == "CVE-2026-39104-esp8266-sdk" }
        assert_equal true, esp_notif["brokeThroughMute"]
        assert_match(/\[Critical Override\]/, esp_notif["title"])

        # 5. Calling dispatch a second time queues 0 duplicates
        post "/api/v1/notifications/dispatch", params: { app_flavor: "tuesday" }, headers: @headers, as: :json
        assert_response :success
        second_body = JSON.parse(response.body)
        assert_equal 0, second_body["queuedCount"]
        assert_operator second_body["skippedExistingCount"], :>=, 4

        # 6. Pending pull & ack transition status cleanly
        get "/api/v1/notifications/pending", headers: @headers
        assert_response :success
        pending_body = JSON.parse(response.body)
        assert_equal 4, pending_body["count"]

        post "/api/v1/notifications/#{cisco_notif['id']}/ack", params: { action_type: "opened" }, headers: @headers, as: :json
        assert_response :success
        ack_body = JSON.parse(response.body)
        assert_equal "opened", ack_body.dig("notification", "deliveryStatus")
      end
    end
  end
end
