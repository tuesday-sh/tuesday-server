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

  def test_confirmation_loop_promotes_identifier_to_short_circuit_catalog
    Dir.mktmpdir do |tmpdir|
      ENV["BRONZE_LAKE_DIR"] = tmpdir
      custom_barcode = "UPC-810010079999-TEST"

      # Record user confirmation
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

      # Next scan with that barcode should immediately short-circuit for $0.00!
      scan_result = Discovery::HardwareVisionService.analyze(
        session_id: "test-session-next",
        turn_index: 1,
        client_platform: "ios",
        device_id: "device-iphone",
        provider_override: "auto",
        extracted_identifiers: [custom_barcode],
        images_base64: []
      )

      assert_equal true, scan_result["shortCircuited"]
      assert_equal "Ubiquiti", scan_result["vendor"]
      assert_equal "USW-Enterprise-8-PoE", scan_result["model"]
      assert_equal 0.0, scan_result["costUSD"]
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
end
