# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../app/services/bulletins/inbox_assembler"

class BulletinsInboxAssemblerTest < Minitest::Test
  def setup
    @feeds = [
      Bulletins::InboxAssembler::CanonicalFeedStruct.new(
        id: "feed-1",
        slug: "cpsc-safety",
        pro_name: "CPSC Consumer Safety Recalls",
        stn_name: "CPSC Home & Nursery Safety Recalls",
        purl_prefixes: ["pkg:generic/owlet/"]
      ),
      Bulletins::InboxAssembler::CanonicalFeedStruct.new(
        id: "feed-2",
        slug: "lg-esphome-iot",
        pro_name: "LG webOS TV & ESPHome IoT Feed",
        stn_name: "LG Smart TV & Garage Smart Relay Feed",
        purl_prefixes: ["pkg:generic/lg/webos", "pkg:generic/esphome/"]
      ),
      Bulletins::InboxAssembler::CanonicalFeedStruct.new(
        id: "feed-3-ecobee-umbrella",
        slug: "ecobee-umbrella",
        pro_name: "Ecobee Smart Thermostat Family Feed (Guessed)",
        stn_name: "Ecobee Thermostat Safety & Updates (Best Guess)",
        purl_prefixes: ["pkg:generic/ecobee/"]
      ),
      Bulletins::InboxAssembler::CanonicalFeedStruct.new(
        id: "feed-4-ecobee-extra",
        slug: "ecobee-beta-sdk",
        pro_name: "Ecobee Secondary Speculative Feed",
        stn_name: "Ecobee Extra Feed",
        purl_prefixes: ["pkg:generic/ecobee/"]
      ),
      Bulletins::InboxAssembler::CanonicalFeedStruct.new(
        id: "feed-unrelated",
        slug: "cisco-ios-xe-enterprise",
        pro_name: "Cisco Catalyst IOS-XE Advisories",
        stn_name: "Cisco Enterprise Routers",
        purl_prefixes: ["pkg:generic/cisco/ios-xe"]
      )
    ]

    @devices = [
      Bulletins::InboxAssembler::TrackedDeviceStruct.new(
        id: "dev-9",
        port_index: 9,
        short_label: "Baby Cam",
        purls: ["pkg:generic/owlet/cam-2@2.1.4"],
        confidence_tier: :confirmed
      ),
      Bulletins::InboxAssembler::TrackedDeviceStruct.new(
        id: "dev-10",
        port_index: 10,
        short_label: "LG OLED",
        purls: ["pkg:generic/lg/webos@8.1.0"],
        confidence_tier: :confirmed
      ),
      Bulletins::InboxAssembler::TrackedDeviceStruct.new(
        id: "dev-11",
        port_index: 11,
        short_label: "Garage ESP",
        purls: ["pkg:generic/esphome/firmware@2026.9.0"],
        confidence_tier: :confirmed
      )
    ]

    @bulletins = [
      Bulletins::InboxAssembler::CuratedBulletinStruct.new(
        external_id: "CPSC-26-104",
        canonical_feed_id: "feed-1",
        bulletin_type: "recall",
        is_high_sev: true,
        purl_base: "pkg:generic/owlet/cam-2",
        pro_title: "CPSC-26-104: Owlet Cam 2 Thermal Recall",
        pro_body: "Inspect USB-C power cord.",
        stn_title: "Safety Recall: Nursery Baby Monitor",
        stn_body: "Check the power cord.",
        ai_pro_bullet: "1 Physical Recall (Port #09): CPSC-26-104 Owlet Cam 2.",
        ai_stn_bullet: "Safety Recall (Nursery Baby Monitor): Replace cord.",
        published_at: "2026-11-01T18:00:00Z"
      ),
      Bulletins::InboxAssembler::CuratedBulletinStruct.new(
        external_id: "CVE-2026-21099",
        canonical_feed_id: "feed-2",
        bulletin_type: "cisa_kev",
        is_high_sev: true,
        purl_base: "pkg:generic/lg/webos",
        pro_title: "CVE-2026-21099 (CISA KEV): LG webOS Auth Bypass",
        pro_body: "Upgrade to webOS 8.3.0.",
        stn_title: "Critical Security Fix: Living Room LG TV",
        stn_body: "Install software update 8.3.0.",
        ai_pro_bullet: "1 CISA KEV Exploit (Port #10): LG webOS auth bypass.",
        ai_stn_bullet: "Critical TV Update (Living Room LG TV): Install 8.3.0.",
        published_at: "2026-11-01T15:00:00Z"
      ),
      Bulletins::InboxAssembler::CuratedBulletinStruct.new(
        external_id: "REL-esphome-2026.10.2",
        canonical_feed_id: "feed-2",
        bulletin_type: "release",
        is_high_sev: false,
        purl_base: "pkg:generic/esphome/firmware",
        pro_title: "ESPHome 2026.10.2 Minor Release",
        pro_body: "Minor Wi-Fi reconnect fix.",
        stn_title: "Minor Feature Update: Garage Relay",
        stn_body: "ESPHome 2026.10.2 stability update.",
        ai_pro_bullet: "1 IoT Release (Port #11): ESPHome 2026.10.2.",
        ai_stn_bullet: "1 Smart Home Update: Garage Relay.",
        published_at: "2026-10-30T12:00:00Z"
      )
    ]
  end

  def test_hides_unmatched_backend_feeds
    result = Bulletins::InboxAssembler.assemble(
      canonical_feeds: @feeds,
      tracked_devices: @devices,
      muted_feed_ids: [],
      curated_bulletins: @bulletins,
      app_flavor: "tuesday"
    )

    matched_slugs = result[:matched_feeds].map { |f| f[:slug] }
    assert_equal ["cpsc-safety", "lg-esphome-iot"], matched_slugs
    refute_includes matched_slugs, "cisco-ios-xe-enterprise"
  end

  def test_muted_feed_excluded_from_ai_summary_and_hides_routine_release_but_overrides_high_sev
    result = Bulletins::InboxAssembler.assemble(
      canonical_feeds: @feeds,
      tracked_devices: @devices,
      muted_feed_ids: ["feed-2"],
      curated_bulletins: @bulletins,
      app_flavor: "tuesday"
    )

    assert_equal 1, result[:ai_summary][:active_feed_count]
    assert_equal 1, result[:ai_summary][:muted_feed_count]
    assert_equal 1, result[:ai_summary][:muted_high_sev_override_count]
    assert_equal ["1 Physical Recall (Port #09): CPSC-26-104 Owlet Cam 2."], result[:ai_summary][:bullets]

    inbox_ids = result[:inbox].map { |i| i[:external_id] }
    assert_equal ["CPSC-26-104", "CVE-2026-21099"], inbox_ids
    refute_includes inbox_ids, "REL-esphome-2026.10.2"

    kev_item = result[:inbox].find { |i| i[:external_id] == "CVE-2026-21099" }
    assert_equal true, kev_item[:broke_through_mute]
  end

  def test_best_guess_device_rules_umbrella_cap_high_sev_guardrail_and_negative_pruning
    guessed_thermostat = Bulletins::InboxAssembler::TrackedDeviceStruct.new(
      id: "dev-12",
      port_index: 12,
      short_label: "Thermostat",
      purls: ["pkg:generic/ecobee/*"],
      confidence_tier: :provisional_guess,
      candidate_models: ["Ecobee SmartThermostat Premium", "Ecobee3 Lite"],
      excluded_purl_prefixes: ["pkg:generic/ecobee/ecobee4"]
    )

    opaque_pi = Bulletins::InboxAssembler::TrackedDeviceStruct.new(
      id: "dev-6",
      port_index: 6,
      short_label: "Unknown Node",
      purls: ["pkg:generic/unknown/*"],
      confidence_tier: :opaque_unknown
    )

    ecobee_bulletins = [
      # 1. Routine firmware release on guessed Ecobee -> MUST BE SUPPRESSED
      Bulletins::InboxAssembler::CuratedBulletinStruct.new(
        external_id: "REL-ecobee-4.8.7",
        canonical_feed_id: "feed-3-ecobee-umbrella",
        bulletin_type: "release",
        is_high_sev: false,
        purl_base: "pkg:generic/ecobee/smart-thermostat",
        pro_title: "Ecobee Firmware 4.8.7.220 Release",
        pro_body: "Routine radar sensor tuning.",
        stn_title: "Ecobee Routine Update",
        stn_body: "Minor sensor tuning.",
        ai_pro_bullet: "Ecobee routine release.",
        ai_stn_bullet: "Ecobee routine release.",
        published_at: "2026-10-31T10:00:00Z"
      ),
      # 2. High-Sev CVE on guessed Ecobee family -> MUST BREAK THROUGH with matched_by_guess: true
      Bulletins::InboxAssembler::CuratedBulletinStruct.new(
        external_id: "CVE-2026-88901",
        canonical_feed_id: "feed-3-ecobee-umbrella",
        bulletin_type: "cve",
        is_high_sev: true,
        purl_base: "pkg:generic/ecobee/smart-thermostat",
        pro_title: "CVE-2026-88901: Ecobee HomeKit Pairing PIN Bypass",
        pro_body: "High-severity local pairing vulnerability on Ecobee SmartThermostat family.",
        stn_title: "Security Warning for Guessed Ecobee Thermostat",
        stn_body: "Confirm your thermostat model to verify if this security fix applies.",
        ai_pro_bullet: "Guessed Ecobee CVE.",
        ai_stn_bullet: "Guessed Ecobee CVE.",
        published_at: "2026-11-01T12:00:00Z"
      ),
      # 3. High-Sev CVE on negatively pruned sub-model (ecobee4) -> MUST BE PRUNED
      Bulletins::InboxAssembler::CuratedBulletinStruct.new(
        external_id: "CVE-2026-77777",
        canonical_feed_id: "feed-3-ecobee-umbrella",
        bulletin_type: "cve",
        is_high_sev: true,
        purl_base: "pkg:generic/ecobee/ecobee4",
        pro_title: "CVE-2026-77777: Legacy Ecobee4 Mic Bug",
        pro_body: "Only affects Ecobee4.",
        stn_title: "Legacy Ecobee4 Issue",
        stn_body: "Only affects Ecobee4.",
        ai_pro_bullet: "Ecobee4 bug.",
        ai_stn_bullet: "Ecobee4 bug.",
        published_at: "2026-11-01T11:00:00Z"
      )
    ]

    result = Bulletins::InboxAssembler.assemble(
      canonical_feeds: @feeds,
      tracked_devices: @devices + [guessed_thermostat, opaque_pi],
      muted_feed_ids: [],
      curated_bulletins: @bulletins + ecobee_bulletins,
      app_flavor: "tuesday"
    )

    # Rule 3: Max 1 Umbrella feed attached for guessed device (feed-3-ecobee-umbrella attached, feed-4-ecobee-extra skipped)
    matched_slugs = result[:matched_feeds].map { |f| f[:slug] }
    assert_includes matched_slugs, "ecobee-umbrella"
    refute_includes matched_slugs, "ecobee-beta-sdk"

    ecobee_feed = result[:matched_feeds].find { |f| f[:slug] == "ecobee-umbrella" }
    assert_equal "provisional_guess", ecobee_feed[:match_mode]
    assert_equal ["Ecobee SmartThermostat Premium", "Ecobee3 Lite"], ecobee_feed[:candidate_models]

    # Rule 2: Provisional feed is excluded from AI Summary bullets, but counted in provisional_high_sev_count
    assert_equal 1, result[:ai_summary][:provisional_feed_count]
    assert_equal 1, result[:ai_summary][:provisional_high_sev_count]
    refute_includes result[:ai_summary][:bullets], "Guessed Ecobee CVE."

    # Rule 2, 4, 5: Routine release & negatively pruned ecobee4 are suppressed; High-Sev CVE-2026-88901 breaks through with disambiguation candidates
    inbox_ids = result[:inbox].map { |i| i[:external_id] }
    assert_includes inbox_ids, "CVE-2026-88901"
    refute_includes inbox_ids, "REL-ecobee-4.8.7"
    refute_includes inbox_ids, "CVE-2026-77777"

    guessed_item = result[:inbox].find { |i| i[:external_id] == "CVE-2026-88901" }
    assert_equal true, guessed_item[:matched_by_guess]
    assert_equal ["Ecobee SmartThermostat Premium", "Ecobee3 Lite"], guessed_item[:candidate_models]
  end
end
