# frozen_string_literal: true

require "test_helper"

module Api
  module V1
    class DiscoveryAndTelemetryFunnelTest < ActionDispatch::IntegrationTest
      setup do
        @headers = {
          "X-Tuesday-Device-ID" => "test-device-pixel9-funnel",
          "X-Tuesday-Client-Platform" => "android"
        }
      end

      test "tracks multi-turn photo + clue discovery funnel and candidate rank confirmation" do
        session_id = "funnel-multi-turn-001"

        # Turn 1: User submits photo (heuristic mode in test)
        post "/api/v1/discovery/analyze",
             params: {
               session_id: session_id,
               turn_index: 1,
               initial_mode: "photo_wizard",
               provider_override: "heuristic",
               images_base64: ["dGVzdF9pbWFnZV9ieXRlcw=="]
             },
             headers: @headers
        assert_response :success

        # Turn 2: User adds a model clue chip -> hits Tier 1 short-circuit (0 LLM turns)
        post "/api/v1/discovery/analyze",
             params: {
               session_id: session_id,
               turn_index: 2,
               provider_override: "auto",
               extracted_identifiers: ["Model: UCG-Ultra"],
               user_clue_notes: ["Model Number=UCG-Ultra"]
             },
             headers: @headers
        assert_response :success
        t2_body = JSON.parse(response.body)
        assert_equal true, t2_body["shortCircuited"]

        # Terminal Resolution: User picks Candidate #0
        post "/api/v1/discovery/resolve",
             params: {
               session_id: session_id,
               resolution_status: "confirmed_candidate",
               selected_candidate_rank: 0,
               inferred_vendor: "Ubiquiti Inc.",
               inferred_model: "UCG-Ultra",
               confirmed_vendor: "Ubiquiti Inc.",
               confirmed_model: "UCG-Ultra",
               was_edited: false,
               extracted_identifiers: ["Model: UCG-Ultra"],
               user_clue_notes: ["Model Number=UCG-Ultra"]
             },
             headers: @headers
        assert_response :success
        res_body = JSON.parse(response.body)
        assert_equal "confirmed", res_body["status"]
        assert_equal "confirmed_candidate", res_body["resolutionStatus"]
        assert_equal 0, res_body["selectedCandidateRank"]
        assert_equal "confirmed", res_body.dig("enrolledDevice", "confidence_tier")

        # Verify relational DiscoverySession & DiscoveryTurn records
        session = DiscoverySession.find_by!(session_id: session_id)
        assert_equal 2, session.turns_count
        assert_equal 2, session.discovery_turns.count
        assert_equal 1, session.total_photos_submitted
        assert_equal 1, session.short_circuited_turns
        assert_equal "confirmed_candidate", session.resolution_status
        assert_equal 0, session.selected_candidate_rank
        assert_not_nil session.monitored_device_id

        turn1, turn2 = session.discovery_turns.to_a
        assert_equal "tier3_heuristic", turn1.routing_tier
        assert_equal 1, turn1.image_count
        assert_equal "tier1_short_circuit", turn2.routing_tier
        assert_includes %w[confirmed_identifier built_in_signature], turn2.short_circuit_source
      ensure
        FileUtils.rm_f(Discovery::HardwareVisionService::RUNTIME_CONFIRMED_CATALOG_FILE)
      end

      test "tracks saved_best_guess, pivoted_to_barcode, pivoted_to_manual, and abandoned_discarded outcomes" do
        # 1. saved_best_guess enrolls provisional_guess MonitoredDevice and flags needs_catalog_review
        post "/api/v1/discovery/analyze",
             params: {
               session_id: "funnel-guess-002",
               turn_index: 1,
               provider_override: "heuristic",
               images_base64: ["dGVzdF9pbWFnZQ=="]
             },
             headers: @headers
        assert_response :success

        post "/api/v1/discovery/resolve",
             params: {
               session_id: "funnel-guess-002",
               resolution_status: "saved_best_guess",
               inferred_vendor: "Ubiquiti Inc.",
               inferred_model: "UCG-Ultra",
               candidate_models: ["UCG-Ultra", "GL-MT3000"]
             },
             headers: @headers
        assert_response :success
        guess_body = JSON.parse(response.body)
        assert_equal "saved_best_guess", guess_body["resolutionStatus"]
        assert_equal true, guess_body["needsCatalogReview"]
        assert_equal "provisional_guess", guess_body.dig("enrolledDevice", "confidence_tier")
        assert_equal "guessed", guess_body.dig("enrolledDevice", "port_state")

        # 2. pivoted_to_manual records the manual fallback and flags catalog expansion queue
        post "/api/v1/discovery/resolve",
             params: {
               session_id: "funnel-manual-003",
               resolution_status: "pivoted_to_manual",
               initial_mode: "photo_wizard",
               final_mode: "manual_agent",
               confirmed_vendor: "CustomVendor",
               confirmed_model: "CustomBox-X1"
             },
             headers: @headers
        assert_response :success
        man_session = DiscoverySession.find_by!(session_id: "funnel-manual-003")
        assert_equal "pivoted_to_manual", man_session.resolution_status
        assert_equal "manual_agent", man_session.final_mode
        assert_equal true, man_session.needs_catalog_review

        # 3. abandoned_discarded closes session without requiring vendor/model
        post "/api/v1/discovery/resolve",
             params: {
               session_id: "funnel-abandon-004",
               resolution_status: "abandoned_discarded",
               enroll: false
             },
             headers: @headers
        assert_response :success
        ab_session = DiscoverySession.find_by!(session_id: "funnel-abandon-004")
        assert_equal "abandoned_discarded", ab_session.resolution_status
        assert_nil ab_session.monitored_device_id
      end

      test "POST /api/v1/telemetry/events ingests batched product events and GET /api/v1/telemetry/summary returns funnel digest" do
        post "/api/v1/telemetry/events",
             params: {
               events: [
                 {
                   event_name: "bulletin.step_toggled",
                   target_entity_type: "CuratedBulletin",
                   target_entity_id: "CVE-2026-1001",
                   properties: { stepIndex: 0, checked: true }
                 },
                 {
                   event_name: "bulletin.marked_complete",
                   target_entity_type: "CuratedBulletin",
                   target_entity_id: "CVE-2026-1001",
                   properties: { totalSteps: 3, timeToCompleteSec: 42 }
                 },
                 {
                   event_name: "checkup.completed",
                   properties: { verifiedDeviceCount: 8, durationSec: 185 }
                 }
               ]
             },
             headers: @headers
        assert_response :created
        batch_body = JSON.parse(response.body)
        assert_equal "recorded", batch_body["status"]
        assert_equal 3, batch_body["recordedCount"]

        get "/api/v1/telemetry/summary", headers: @headers
        assert_response :success
        summary = JSON.parse(response.body)
        assert_equal "ok", summary["status"]
        assert summary.dig("productEventsByDomain", "bulletin").to_i >= 2
        assert summary.dig("productEventsByDomain", "checkup").to_i >= 1
        assert summary.key?("discoveryFunnel")
        assert summary.key?("catalogExpansionQueue")
      end
    end
  end
end
