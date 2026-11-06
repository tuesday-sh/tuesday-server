# frozen_string_literal: true

require "test_helper"

module Api
  module V1
    class InventoryAndBillingControllerTest < ActionDispatch::IntegrationTest
      setup do
        @headers = {
          "X-Tuesday-Device-ID" => "test-device-pixel9-001",
          "X-Tuesday-Client-Platform" => "android"
        }
      end

      test "GET /api/v1/inventory falls back to canonical 12-device fixture when site not yet persisted" do
        get "/api/v1/inventory", headers: @headers
        assert_response :success
        body = JSON.parse(response.body)
        assert_equal 128, body["led_matrix_total"]
        assert_equal "non_green_only", body["action_list_mode"]
        assert_equal 9, body["devices"].size
      end

      test "POST /api/v1/inventory creates NetworkSite and enrolls MonitoredDevice in port 1..128" do
        post "/api/v1/inventory",
             params: {
               vendor: "Ubiquiti",
               model_number: "USW-Pro-Max-24",
               name: "Core Rack Switch",
               category_code: "C2",
               trust_zone: "z0_core",
               port_state: "update",
               version: "7.0.50",
               target_version: "7.1.26",
               purls: ["pkg:generic/ui/usw-pro-max@7.0.50"]
             },
             headers: @headers

        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "created", body["status"]
        assert_equal 1, body.dig("device", "port_index")
        assert_equal "C2", body.dig("device", "category_code")
        assert_equal "pea", body.dig("site", "site_tier")

        # Subsequent GET /api/v1/inventory returns the persisted 1-device Pea site
        get "/api/v1/inventory", params: { include_ok: true }, headers: @headers
        assert_response :success
        inv = JSON.parse(response.body)
        assert_equal 1, inv["devices"].size
        assert_equal "USW-Pro-Max-24", inv["devices"].first["model_number"]
      end

      test "PATCH /api/v1/inventory/:id marks remediation complete and disambiguates candidate models" do
        # Seed the 12-device Forest site first
        post "/api/v1/inventory/seed_demo", params: { mode: "forest" }, headers: @headers
        assert_response :success

        # 1. Mark MacBook M4 update complete -> port_state becomes ok and version advances to target_version
        patch "/api/v1/inventory/0192d9f0-0010-7000-8000-000000000110",
              params: { mark_remediated: true },
              headers: @headers
        assert_response :success
        updated = JSON.parse(response.body)
        assert_equal "ok", updated.dig("device", "port_state")
        assert_equal "15.3.2", updated.dig("device", "version")

        # 2. Disambiguate guessed Hallway Smart Thermostat -> confidence_tier becomes confirmed
        patch "/api/v1/inventory/0192d9f0-0012-7000-8000-000000000112",
              params: {
                confirmed_candidate_model: "SmartThermostat Premium",
                add_excluded_purl_prefix: "pkg:generic/ecobee/ecobee3-lite"
              },
              headers: @headers
        assert_response :success
        thermostat = JSON.parse(response.body)
        assert_equal "confirmed", thermostat.dig("device", "confidence_tier")
        assert_includes thermostat.dig("device", "excluded_purl_prefixes"), "pkg:generic/ecobee/ecobee3-lite"
      end

      test "POST /api/v1/discovery/confirm automatically enrolls confirmed hardware into caller NetworkSite" do
        post "/api/v1/discovery/confirm",
             params: {
               session_id: "scan-101",
               inferred_vendor: "Synology",
               inferred_model: "NAS",
               confirmed_vendor: "Synology",
               confirmed_model: "DS923+",
               was_edited: true,
               suggested_trust_zone: "z2_lab",
               category_code: "C3"
             },
             headers: @headers

        assert_response :success
        body = JSON.parse(response.body)
        assert_equal "confirmed", body["status"]
        assert_equal "DS923+", body.dig("enrolledDevice", "model_number")
        assert_equal "z2_lab", body.dig("enrolledDevice", "trust_zone")
        assert_equal 1, body.dig("enrolledDevice", "port_index")
      end

      test "POST /api/v1/billing/verify upgrades site entitlement_tier to pro_tier_1" do
        post "/api/v1/billing/verify",
             params: {
               platform: "ios",
               product_id: "sh.tuesday.pro.tier1.annual",
               transaction_jws: "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.test_jws_payload"
             },
             headers: @headers

        assert_response :success
        body = JSON.parse(response.body)
        assert_equal "verified", body["status"]
        assert_equal "pro_tier_1", body["entitlementTier"]
        assert_equal 128, body["maxPorts"]
      end
    end
  end
end
