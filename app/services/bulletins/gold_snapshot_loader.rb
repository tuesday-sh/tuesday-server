# frozen_string_literal: true

require "json"
require_relative "inbox_assembler"

module Bulletins
  # Dual-Mode Gold Data Lake Snapshot Loader & Inventory Matrix Assembler.
  #
  # Loads canonical Gold JSON snapshots from `tuesday-datalake/gold/*.json`
  # (zero GCP credentials or live 3rd-party HTTP calls required) and assembles:
  # 1. The Bulletins payload (AI Summary + Matched Feeds + High-Sev Override Inbox + Best-Guess Rules)
  # 2. The 128-LED Status Matrix (ordered Z0 -> Z4) + Action-First Inventory List (defaulting to non-Green devices)
  class GoldSnapshotLoader
    DEFAULT_LAKE_DIR = File.expand_path("../../../../../tuesday-datalake/gold", __FILE__)

    TRUST_ZONE_ORDER = {
      "z0_core" => 0,
      "z1_trusted" => 1,
      "z2_lab" => 2,
      "z3_iot" => 3,
      "z4_guest" => 4
    }.freeze

    PORT_STATE_PRIORITY = {
      "cve_kev" => 1,
      "eol" => 2,
      "guessed" => 3,
      "update" => 4,
      "ok" => 5
    }.freeze

    def self.load_gold_feeds(lake_dir: ENV.fetch("GOLD_LAKE_DIR", DEFAULT_LAKE_DIR))
      raw = JSON.parse(File.read(File.join(lake_dir, "canonical_feeds.json")))
      raw.map do |row|
        InboxAssembler::CanonicalFeedStruct.new(
          id: row["id"],
          slug: row["slug"],
          pro_name: row["pro_name"],
          stn_name: row["stn_name"],
          purl_prefixes: row["purl_prefixes"]
        )
      end
    end

    def self.load_gold_bulletins(lake_dir: ENV.fetch("GOLD_LAKE_DIR", DEFAULT_LAKE_DIR), feeds_by_slug: nil)
      feeds_by_slug ||= load_gold_feeds(lake_dir: lake_dir).each_with_object({}) { |f, h| h[f.slug] = f }
      raw = JSON.parse(File.read(File.join(lake_dir, "curated_bulletins.json")))
      raw.map do |row|
        feed = feeds_by_slug[row["canonical_feed_slug"]]
        InboxAssembler::CuratedBulletinStruct.new(
          external_id: row["external_id"],
          canonical_feed_id: feed&.id || row["canonical_feed_slug"],
          bulletin_type: row["bulletin_type"],
          is_high_sev: row["is_high_sev"],
          purl_base: row["purl_base"],
          pro_title: row["pro_title"],
          pro_body: row["pro_body"],
          stn_title: row["stn_title"],
          stn_body: row["stn_body"],
          ai_pro_bullet: row["ai_pro_bullet"],
          ai_stn_bullet: row["ai_stn_bullet"],
          published_at: row["published_at"]
        )
      end
    end

    def self.golden_tracked_devices
      [
        {
          id: "0192d9f0-0008-7000-8000-000000000108",
          port_index: 1,
          port_state: "cve_kev",
          trust_zone: "z0_core",
          asset_tag: "STN-GW-01",
          short_label: "UDM-Pro",
          name: "Main Rack UniFi Dream Machine Pro",
          room_location: "Basement Rack U02",
          version: "4.0.20",
          target_version: "4.0.20",
          lifecycle_tier: "active",
          purls: ["pkg:generic/ui/unifi-os@4.0.20"],
          confidence_tier: :confirmed,
          candidate_models: [],
          excluded_purl_prefixes: []
        },
        {
          id: "0192d9f0-0005-7000-8000-000000000105",
          port_index: 2,
          port_state: "eol",
          trust_zone: "z0_core",
          asset_tag: "STN-AP-00",
          short_label: "R7000 AP",
          name: "Basement Netgear R7000",
          room_location: "Basement Workbench",
          version: "1.0.11.136",
          target_version: nil,
          lifecycle_tier: "legacy",
          purls: ["pkg:generic/netgear/r7000@1.0.11.136"],
          confidence_tier: :confirmed,
          candidate_models: [],
          excluded_purl_prefixes: []
        },
        {
          id: "0192d9f0-0009-7000-8000-000000000109",
          port_index: 3,
          port_state: "ok",
          trust_zone: "z0_core",
          asset_tag: "STN-AP-01",
          short_label: "U7-Pro",
          name: "Living Room Ceiling UniFi U7 Pro",
          room_location: "1F Living Room",
          version: "7.0.66",
          target_version: "7.0.66",
          lifecycle_tier: "active",
          purls: ["pkg:generic/ui/u7-pro@7.0.66"],
          confidence_tier: :confirmed,
          candidate_models: [],
          excluded_purl_prefixes: []
        },
        {
          id: "0192d9f0-0004-7000-8000-000000000104",
          port_index: 4,
          port_state: "ok",
          trust_zone: "z1_trusted",
          asset_tag: "STN-CL-01",
          short_label: "Switch 2",
          name: "Living Room Nintendo Switch 2",
          room_location: "1F Media Console",
          version: "19.0.1",
          target_version: "19.0.1",
          lifecycle_tier: "active",
          purls: ["pkg:generic/nintendo/horizon-os@19.0.1"],
          confidence_tier: :confirmed,
          candidate_models: [],
          excluded_purl_prefixes: []
        },
        {
          id: "0192d9f0-0010-7000-8000-000000000110",
          port_index: 5,
          port_state: "update",
          trust_zone: "z1_trusted",
          asset_tag: "STN-CL-02",
          short_label: "MacBook M4",
          name: "Aaron's MacBook Pro 16 (M4 Max)",
          room_location: "2F Office Desk",
          version: "15.3.1",
          target_version: "15.3.2",
          lifecycle_tier: "active",
          purls: ["pkg:generic/apple/macos@15.3.1"],
          confidence_tier: :confirmed,
          candidate_models: [],
          excluded_purl_prefixes: []
        },
        {
          id: "0192d9f0-0001-7000-8000-000000000101",
          port_index: 6,
          port_state: "guessed",
          trust_zone: "z2_lab",
          asset_tag: "STN-LAB-09",
          short_label: "Unknown Pi",
          name: "Unidentified Raspberry Pi 5 Node",
          room_location: "Basement Rack Shelf",
          version: "unverified",
          target_version: nil,
          lifecycle_tier: "active",
          purls: ["pkg:generic/unknown/*"],
          confidence_tier: :opaque_unknown,
          candidate_models: [],
          excluded_purl_prefixes: []
        },
        {
          id: "0192d9f0-0002-7000-8000-000000000102",
          port_index: 7,
          port_state: "ok",
          trust_zone: "z2_lab",
          asset_tag: "STN-NAS-01",
          short_label: "unraid-lml",
          name: "Unraid Storage Server (lml)",
          room_location: "Basement Rack U06",
          version: "7.0.0",
          target_version: "7.0.0",
          lifecycle_tier: "active",
          purls: ["pkg:generic/limetech/unraid@7.0.0"],
          confidence_tier: :confirmed,
          candidate_models: [],
          excluded_purl_prefixes: []
        },
        {
          id: "0192d9f0-0011-7000-8000-000000000111",
          port_index: 8,
          port_state: "update",
          trust_zone: "z2_lab",
          asset_tag: "STN-LAB-02",
          short_label: "Proxmox VE",
          name: "Homelab Hypervisor (pve-node-01)",
          room_location: "Basement Rack U04",
          version: "8.3.1",
          target_version: "8.3.2",
          lifecycle_tier: "active",
          purls: ["pkg:deb/debian/proxmox-ve@8.3.1"],
          confidence_tier: :confirmed,
          candidate_models: [],
          excluded_purl_prefixes: []
        },
        {
          id: "0192d9f0-0006-7000-8000-000000000106",
          port_index: 9,
          port_state: "cve_kev",
          trust_zone: "z3_iot",
          asset_tag: "STN-CAM-01",
          short_label: "Baby Cam",
          name: "Nursery Baby Monitor",
          room_location: "2F Nursery",
          version: "1.0.4",
          target_version: "2.1.0",
          lifecycle_tier: "active",
          purls: ["pkg:generic/owlet/cam-2@1.0.4"],
          confidence_tier: :confirmed,
          candidate_models: [],
          excluded_purl_prefixes: []
        },
        {
          id: "0192d9f0-0007-7000-8000-000000000107",
          port_index: 10,
          port_state: "cve_kev",
          trust_zone: "z3_iot",
          asset_tag: "STN-IOT-01",
          short_label: "LG OLED",
          name: "Living Room LG OLED TV",
          room_location: "1F Living Room",
          version: "8.1.0",
          target_version: "8.3.0",
          lifecycle_tier: "vintage",
          purls: ["pkg:generic/lg/webos@8.1.0"],
          confidence_tier: :confirmed,
          candidate_models: [],
          excluded_purl_prefixes: []
        },
        {
          id: "0192d9f0-0003-7000-8000-000000000103",
          port_index: 11,
          port_state: "update",
          trust_zone: "z3_iot",
          asset_tag: "STN-IOT-04",
          short_label: "Garage ESP",
          name: "Garage Door Relay ESP32",
          room_location: "Garage Ceiling",
          version: "2026.9.0",
          target_version: "2026.10.2",
          lifecycle_tier: "active",
          purls: ["pkg:generic/esphome/firmware@2026.9.0"],
          confidence_tier: :confirmed,
          candidate_models: [],
          excluded_purl_prefixes: []
        },
        {
          id: "0192d9f0-0012-7000-8000-000000000112",
          port_index: 12,
          port_state: "guessed",
          trust_zone: "z3_iot",
          asset_tag: "STN-IOT-09",
          short_label: "Thermostat",
          name: "Hallway Smart Thermostat",
          room_location: "1F Hallway",
          version: "unverified",
          target_version: nil,
          lifecycle_tier: "active",
          purls: ["pkg:generic/ecobee/*"],
          confidence_tier: :provisional_guess,
          candidate_models: ["SmartThermostat Premium", "Ecobee3 Lite"],
          excluded_purl_prefixes: []
        }
      ]
    end

    def self.assemble_bulletins_from_gold(
      app_flavor: "tuesday",
      muted_feed_slugs: ["lg-esphome-iot"],
      lake_dir: ENV.fetch("GOLD_LAKE_DIR", DEFAULT_LAKE_DIR)
    )
      feeds = load_gold_feeds(lake_dir: lake_dir)
      feeds_by_slug = feeds.each_with_object({}) { |f, h| h[f.slug] = f }
      bulletins = load_gold_bulletins(lake_dir: lake_dir, feeds_by_slug: feeds_by_slug)

      devices = golden_tracked_devices.map do |d|
        InboxAssembler::TrackedDeviceStruct.new(
          id: d[:id],
          port_index: d[:port_index],
          short_label: d[:short_label],
          purls: d[:purls],
          confidence_tier: d[:confidence_tier],
          candidate_models: d[:candidate_models],
          excluded_purl_prefixes: d[:excluded_purl_prefixes]
        )
      end

      muted_ids = Array(muted_feed_slugs).filter_map { |slug| feeds_by_slug[slug]&.id }

      InboxAssembler.assemble(
        canonical_feeds: feeds,
        tracked_devices: devices,
        muted_feed_ids: muted_ids,
        curated_bulletins: bulletins,
        app_flavor: app_flavor
      )
    end

    # Builds the 128-LED At-a-Glance Status Matrix (ordered Z0 -> Z4) and the Action-First Device List
    def self.assemble_inventory(include_ok: false, zone_filter: "all")
      named_devices = golden_tracked_devices
      zone_counts = {
        "z0_core" => 16,
        "z1_trusted" => 32,
        "z2_lab" => 24,
        "z3_iot" => 40,
        "z4_guest" => 16
      }

      led_matrix = []
      zone_counts.each do |zone_key, total_slots|
        next if zone_filter != "all" && zone_filter != zone_key

        in_zone = named_devices
          .select { |d| d[:trust_zone] == zone_key }
          .sort_by { |d| PORT_STATE_PRIORITY.fetch(d[:port_state], 99) }

        in_zone.each do |dev|
          led_matrix << {
            state: dev[:port_state],
            trust_zone: zone_key,
            device_id: dev[:id],
            port_index: dev[:port_index]
          }
        end

        remaining_ok = [0, total_slots - in_zone.size].max
        remaining_ok.times do
          led_matrix << {
            state: "ok",
            trust_zone: zone_key,
            device_id: nil,
            port_index: nil
          }
        end
      end

      filtered_devices = named_devices.select do |d|
        (zone_filter == "all" || d[:trust_zone] == zone_filter) &&
          (include_ok || d[:port_state] != "ok")
      end.sort_by do |d|
        [PORT_STATE_PRIORITY.fetch(d[:port_state], 99), TRUST_ZONE_ORDER.fetch(d[:trust_zone], 99)]
      end

      {
        led_matrix_total: led_matrix.size,
        led_counts: {
          ok: led_matrix.count { |l| l[:state] == "ok" },
          cve_kev: led_matrix.count { |l| l[:state] == "cve_kev" },
          eol: led_matrix.count { |l| l[:state] == "eol" },
          guessed: led_matrix.count { |l| l[:state] == "guessed" },
          update: led_matrix.count { |l| l[:state] == "update" }
        },
        led_matrix: led_matrix,
        action_list_mode: include_ok ? "all_devices" : "non_green_only",
        devices: filtered_devices
      }
    end
  end
end
