# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../app/services/bulletins/gold_snapshot_loader"

class GoldSnapshotLoaderTest < Minitest::Test
  def test_assemble_bulletins_from_gold_snapshot
    lake_dir = ENV.fetch("GOLD_LAKE_DIR", Bulletins::GoldSnapshotLoader::DEFAULT_LAKE_DIR)
    skip "Sibling tuesday-datalake/gold directory not present (#{lake_dir})" unless File.exist?(File.join(lake_dir, "canonical_feeds.json"))

    payload = Bulletins::GoldSnapshotLoader.assemble_bulletins_from_gold(
      app_flavor: "tuesday",
      muted_feed_slugs: ["lg-esphome-iot"]
    )

    assert_equal 7, payload[:matched_feeds].size
    assert_equal 5, payload[:ai_summary][:active_feed_count]
    assert_equal 1, payload[:ai_summary][:muted_feed_count]
    assert_equal 1, payload[:ai_summary][:provisional_feed_count]
    assert_equal 1, payload[:ai_summary][:muted_high_sev_override_count]
    assert_equal 1, payload[:ai_summary][:provisional_high_sev_count]
    assert_equal 4, payload[:ai_summary][:bullets].size

    # Verify Best-Guess feed (`ecobee-umbrella`) is in provisional_guess mode
    ecobee = payload[:matched_feeds].find { |f| f[:slug] == "ecobee-umbrella" }
    assert_equal "provisional_guess", ecobee[:match_mode]
    assert_includes ecobee[:candidate_models], "SmartThermostat Premium"

    # Verify inbox contains 6 items (4 confirmed unmuted + 1 high-sev override from muted LG feed + 1 high-sev from provisional Ecobee feed)
    # while routine ESPHome (muted) and routine Ecobee (provisional) releases are suppressed.
    assert_equal 6, payload[:inbox].size
    lg_alert = payload[:inbox].find { |b| b[:external_id] == "CVE-2026-21099" }
    assert_equal true, lg_alert[:broke_through_mute]

    ecobee_alert = payload[:inbox].find { |b| b[:external_id] == "CVE-2026-88901" }
    assert_equal true, ecobee_alert[:matched_by_guess]

    routine_ecobee = payload[:inbox].find { |b| b[:external_id] == "REL-ecobee-4.8.7.220" }
    assert_nil routine_ecobee
  end

  def test_assemble_inventory_128_led_matrix_and_action_first_list
    inv = Bulletins::GoldSnapshotLoader.assemble_inventory(include_ok: false, zone_filter: "all")

    assert_equal 128, inv[:led_matrix_total]
    assert_equal 119, inv[:led_counts][:ok]
    assert_equal 3, inv[:led_counts][:cve_kev]
    assert_equal 1, inv[:led_counts][:eol]
    assert_equal 2, inv[:led_counts][:guessed]
    assert_equal 3, inv[:led_counts][:update]

    # Default Action-First mode returns only the 9 non-Green devices ordered by severity priority
    assert_equal "non_green_only", inv[:action_list_mode]
    assert_equal 9, inv[:devices].size
    assert inv[:devices].none? { |d| d[:port_state] == "ok" }
    assert_equal "cve_kev", inv[:devices].first[:port_state]

    # When include_ok is true, all 12 named devices are returned
    inv_all = Bulletins::GoldSnapshotLoader.assemble_inventory(include_ok: true, zone_filter: "all")
    assert_equal "all_devices", inv_all[:action_list_mode]
    assert_equal 12, inv_all[:devices].size
  end
end
