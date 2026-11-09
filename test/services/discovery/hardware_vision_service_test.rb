# frozen_string_literal: true

require "minitest/autorun"
require "active_support/all"
require "tmpdir"

# Minimal Rails shim when run standalone with `ruby -Ilib:test`
unless defined?(Rails) && Rails.respond_to?(:env)
  module Rails
    def self.env
      ActiveSupport::StringInquirer.new("test")
    end

    def self.logger
      @logger ||= Logger.new(IO::NULL)
    end
  end
end

require_relative "../../../app/services/telemetry/hosted_ai_logger"
require_relative "../../../app/services/discovery/hardware_vision_service"

class HardwareVisionServiceTest < Minitest::Test
  def test_catalog_short_circuit_zero_cost_and_ephemeral_image_wipe
    Dir.mktmpdir do |tmpdir|
      ENV["BRONZE_LAKE_DIR"] = tmpdir
      fake_frames = ["base64_jpeg_frame_1_secret", "base64_jpeg_frame_2_secret"]

      result = Discovery::HardwareVisionService.analyze(
        session_id: "test-session-short-circuit",
        turn_index: 1,
        client_platform: "ios",
        device_id: "device-ios-001",
        provider_override: "auto",
        extracted_identifiers: ["Barcode: UDM-Pro", "MAC: 24:5A:4C:11:22:33"],
        images_base64: fake_frames
      )

      assert_equal "Ubiquiti Inc.", result["vendor"]
      assert_equal "UDM-Pro", result["model"]
      assert_equal 1, result["candidates"].size
      assert_equal "UniFi Dream Machine Pro (UDM-Pro)", result["candidates"].first["displayName"]
      assert_equal true, result["shortCircuited"]
      assert_equal "CatalogCache", result["providerUsed"]
      assert_equal "gold-short-circuit", result["modelUsed"]
      assert_equal 0.0, result["costUSD"]
      assert_equal "none_ephemeral_ram_only", result.dig("privacyAttestation", "imageRetention")

      # Verify Bronze JSONL was written with ZERO image fields
      bronze_file = File.join(tmpdir, "vision_inferences.jsonl")
      assert File.exist?(bronze_file)
      raw_line = File.read(bronze_file).lines.last
      refute_includes raw_line, "base64_jpeg_frame"
      logged = JSON.parse(raw_line)
      assert_equal "hosted_ai_call", logged["event"]
      assert_equal "hardware_discovery", logged["feature"]
      assert_equal true, logged["shortCircuited"]
      assert_equal 0.0, logged["costUSD"]
    end
  end

  def test_confirmation_logs_user_selection_without_promoting_to_gold_catalog
    Dir.mktmpdir do |tmpdir|
      ENV["BRONZE_LAKE_DIR"] = tmpdir
      custom_barcode = "UPC-810010079999-TEST"

      # Record user selection: must log what was picked as observational telemetry
      # without assuming the user's pick is ground-truth or mutating the Gold Catalog.
      confirm_record = Discovery::HardwareVisionService.record_confirmation!(
        session_id: "test-session-confirm",
        client_platform: "android",
        device_id: "device-pixel9",
        inferred_vendor: "Ubiquiti",
        inferred_model: "UniFi Switch",
        confirmed_vendor: "Ubiquiti",
        confirmed_model: "USW-Enterprise-8-PoE",
        was_edited: true,
        extracted_identifiers: [custom_barcode],
        suggested_lifecycle_tier: "active",
        suggested_trust_zone: "z0_core"
      )

      assert_equal "hosted_ai_confirm", confirm_record["event"]
      assert_equal "USW-Enterprise-8-PoE", confirm_record["confirmedModel"]
      assert_equal true, confirm_record["wasEdited"]
      assert_equal "unverified_user_pick", confirm_record["selectionVerification"]
      assert_equal false, confirm_record["selectedTopRankUnmodified"]
      refute confirm_record.key?("accuracyScore")
      refute File.exist?(Discovery::HardwareVisionService::RUNTIME_CONFIRMED_CATALOG_FILE)
    ensure
      FileUtils.rm_f(Discovery::HardwareVisionService::RUNTIME_CONFIRMED_CATALOG_FILE)
    end
  end

  def test_cost_calculation_for_elastix_and_gemini
    elastix_cost = Telemetry::HostedAiLogger.calculate_cost_usd(
      model: "qwen3.8-27b",
      input_tokens: 1500,
      output_tokens: 200,
      cache_read_tokens: 500
    )
    # 1000 uncached input * $0.30/1M ($0.0003) + 500 cached * $0.05/1M ($0.000025) + 200 output * $1.20/1M ($0.00024) = $0.000565
    assert_in_delta 0.000565, elastix_cost, 0.000001

    gemini_cost = Telemetry::HostedAiLogger.calculate_cost_usd(
      model: "gemini-3.8-flash",
      input_tokens: 1000,
      output_tokens: 200,
      cache_read_tokens: 0
    )
    # 1000 input * $0.15/1M ($0.00015) + 200 output * $0.60/1M ($0.00012) = $0.00027
    assert_in_delta 0.00027, gemini_cost, 0.000001
  end

  def test_debug_mode_gold_datalake_alignment_and_livetail_log
    Dir.mktmpdir do |tmpdir|
      ENV["BRONZE_LAKE_DIR"] = tmpdir
      result = Discovery::HardwareVisionService.analyze(
        session_id: "test-session-debug-audit",
        turn_index: 1,
        client_platform: "android",
        device_id: "pixel-9-dev",
        provider_override: "heuristic",
        extracted_identifiers: [],
        images_base64: ["dGVzdF9pbWFnZV9ieXRlcw=="],
        debug: true
      )

      assert_equal 2, result["candidates"].size
      first_cand = result["candidates"][0]
      second_cand = result["candidates"][1]

      # Candidate 1 (Ubiquiti UCG-Ultra) aligns with Gold Datalake
      assert_equal true, first_cand.dig("goldAlignment", "aligned")
      assert_equal "GOLD ALIGNED", first_cand.dig("goldAlignment", "statusLabel")
      assert_equal "ubiquiti-advisories", first_cand.dig("goldAlignment", "matchedFeedSlug")

      # Candidate 2 (GL.iNet GL-MT3000) resolves to the GL.iNet vendor feed (`openwrt-glinet-firmware`)
      assert_equal false, second_cand.dig("goldAlignment", "aligned")
      assert_equal true, second_cand.dig("goldAlignment", "vendorFeedOnly")
      assert_equal "UNALIGNED MODEL (VENDOR FEED ONLY)", second_cand.dig("goldAlignment", "statusLabel")
      assert_equal "openwrt-glinet-firmware", second_cand.dig("goldAlignment", "matchedFeedSlug")
      assert_includes second_cand.dig("goldAlignment", "inferredPurl"), "pkg:generic/gl-inet/gl-mt3000"

      # Debug log text and trace are returned
      assert_includes result["debugLogText"], "=== TUESDAY VISION DEBUG LOG"
      assert_includes result["debugLogText"], "[✓ GOLD ALIGNED]"
      assert_includes result["debugLogText"], "[⚠ VENDOR FEED ONLY]"
      assert result["debugTrace"].any? { |t| t.include?("[LLM_PARSE]") }
      assert result["debugTrace"].any? { |t| t.include?("[PURL_RESOLVE]") }
      assert result["debugTrace"].any? { |t| t.include?("[GOLD_AUDIT]") }

      # Livetail files are written with zero base64 image leak
      livetail_log = Telemetry::HostedAiLogger.livetail_log_path(bronze_dir: tmpdir)
      assert File.exist?(livetail_log)
      log_contents = File.read(livetail_log)
      refute_includes log_contents, "dGVzdF9pbWFnZV9ieXRlcw=="
      assert_includes log_contents, "test-session-debug-audit"

      recent = Telemetry::HostedAiLogger.read_recent_livetail(limit: 5, bronze_dir: tmpdir)
      assert_equal 1, recent.size
      assert_equal "test-session-debug-audit", recent.first["sessionId"]
    end
  end

  def test_three_tier_gold_alignment_distinguishes_exact_model_vs_vendor_feed_only
    raw_candidates = [
      {
        "manufacturer" => "Ubiquiti",
        "modelNumber" => "UCG-Ultra",
        "displayName" => "UniFi Cloud Gateway Ultra (UCG-Ultra)",
        "deviceCategory" => "Gateway / Router",
        "confidencePercent" => 92,
        "reasoning" => "Exact UCG-Ultra label.",
        "suggestedHostname" => "ucg-ultra",
        "suggestedOsDetails" => "UniFi OS",
        "suggestedPackageManager" => "firmware"
      },
      {
        "manufacturer" => "Ubiquiti",
        "modelNumber" => "UXG-Prototype-999",
        "displayName" => "UniFi Gateway Prototype 999",
        "deviceCategory" => "Gateway / Router",
        "confidencePercent" => 5,
        "reasoning" => "Similar white desktop enclosure.",
        "suggestedHostname" => "uxg-proto-999",
        "suggestedOsDetails" => "UniFi OS",
        "suggestedPackageManager" => "firmware"
      },
      {
        "manufacturer" => "AcmeNet",
        "modelNumber" => "AR-9999",
        "displayName" => "AcmeNet Prototype Router",
        "deviceCategory" => "Router",
        "confidencePercent" => 2,
        "reasoning" => "Compact white router.",
        "suggestedHostname" => "acmenet-ar9999",
        "suggestedOsDetails" => "OpenWrt",
        "suggestedPackageManager" => "firmware"
      }
    ]

    traces = []
    audited = Discovery::HardwareVisionService.send(
      :audit_candidates_against_gold_datalake,
      raw_candidates,
      trace: ->(stage, msg) { traces << "[#{stage}] #{msg}" }
    )

    # 1. UCG-Ultra -> Exact Model Match (GOLD ALIGNED)
    c1 = audited[0]["goldAlignment"]
    assert_equal "pkg:generic/ui/ucg-ultra", c1["inferredPurl"]
    assert_equal true, c1["aligned"]
    assert_equal false, c1["vendorFeedOnly"]
    assert_equal "GOLD ALIGNED", c1["statusLabel"]
    assert_equal "ubiquiti-advisories", c1["matchedFeedSlug"]

    # 2. UXG-Prototype-999 -> Same vendor prefix (pkg:generic/ui/), but model not in Gold Catalog
    c2 = audited[1]["goldAlignment"]
    assert_equal "pkg:generic/ui/uxg-prototype-999", c2["inferredPurl"]
    assert_equal false, c2["aligned"]
    assert_equal true, c2["vendorFeedOnly"]
    assert_equal "UNALIGNED MODEL (VENDOR FEED ONLY)", c2["statusLabel"]
    assert_equal "ubiquiti-advisories", c2["matchedFeedSlug"]

    # 3. AcmeNet AR-9999 -> Neither model nor vendor prefix in Gold Catalog
    c3 = audited[2]["goldAlignment"]
    assert_equal "pkg:generic/acmenet/ar-9999", c3["inferredPurl"]
    assert_equal false, c3["aligned"]
    assert_equal false, c3["vendorFeedOnly"]
    assert_equal "UNALIGNED RAW MATCH", c3["statusLabel"]
    assert_nil c3["matchedFeedSlug"]

    assert_equal 6, traces.size # 3 PURL_RESOLVE + 3 GOLD_AUDIT
  end

  def test_fcc_id_short_circuit_and_modular_radio_disambiguation
    # 1. Host FCC ID (Netgear CAX80 -> PY320100492) resolves in 0 LLM turns
    res_host = Discovery::HardwareVisionService.analyze(
      session_id: "test-fcc-host",
      extracted_identifiers: ["FCC ID: PY320100492"],
      debug: false
    )
    assert_equal true, res_host["shortCircuited"]
    assert_equal "Netgear", res_host["vendor"]
    assert_equal "CAX80", res_host["model"]
    assert_equal "PY320100492", res_host.dig("extractedIdentifiersObject", "fccId")
    assert_equal "GOLD ALIGNED", res_host.dig("candidates", 0, "goldAlignment", "statusLabel")

    # 2. Modular Radio FCC ID ("Contains FCC ID: 2AC7Z-ESP32WROOM32E") does NOT misidentify outer vendor as Espressif
    res_mod = Discovery::HardwareVisionService.analyze(
      session_id: "test-fcc-module",
      provider_override: "heuristic",
      extracted_identifiers: ["Contains FCC ID: 2AC7Z-ESP32WROOM32E"],
      debug: false
    )
    assert_equal false, res_mod["shortCircuited"]
    assert res_mod["extractedIdentifiers"].any? { |c| c.include?("Embedded Radio Module") && c.include?("ESP32") }
  end
end
