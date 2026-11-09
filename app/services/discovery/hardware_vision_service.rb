# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "fileutils"
require_relative "../bulletins/gold_snapshot_loader"

module Discovery
  # Server-Side Hardware Vision & Catalog Short-Circuit Service.
  #
  # Routing Hierarchy:
  # 1. $0.00 Gold Catalog & Confirmed Identifier Short-Circuit:
  #    Matches extracted barcode/UPC, MAC OUI, or exact model tags in < 5ms for $0.00.
  # 2. Primary Upstream LLM: Elastix.ai (qwen3.8-27b) via /v1/chat/completions.
  # 3. Auto-Failover Upstream LLM: GCP Gemini Interactions API (gemini-3.8-flash).
  # 4. Deterministic Heuristic Fallback (for offline / local test runs without keys).
  #
  # PRIVACY COMPLIANCE INVARIANT:
  # - Base64 camera frames are processed strictly in ephemeral RAM during the upstream
  #   HTTPS request and explicitly cleared in an `ensure` block before returning.
  # - No user photos are ever written to disk, databases, logs, or cloud buckets.
  class HardwareVisionService
    ELASTIX_ENDPOINT = "https://api.elastix.ai/v1/chat/completions"
    GEMINI_INTERACTIONS_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/interactions"

    CONFIRMED_CATALOG_FILE = File.expand_path("../../../../../tuesday-datalake/gold/confirmed_hardware_identifiers.json", __FILE__)
    BUNDLED_CONFIRMED_CATALOG_FILE = File.join(Bulletins::GoldSnapshotLoader::BUNDLED_LAKE_DIR, "confirmed_hardware_identifiers.json")
    RUNTIME_CONFIRMED_CATALOG_FILE = "/tmp/tuesday-datalake/gold/confirmed_hardware_identifiers.json"

    PRIVACY_ATTESTATION = {
      "imageRetention" => "none_ephemeral_ram_only",
      "persistedFields" => %w[extractedIdentifiers inferredVendor inferredModel latencyMs tokenUsage]
    }.freeze

    DEFAULT_CLUE_TYPES = ["Model", "MAC Address", "Serial Number", "Barcode", "QR Code"].freeze

    BUILT_IN_CATALOG_SIGNATURES = [
      {
        pattern: /\b(UDM-PRO|UDM\s*PRO)\b/i,
        vendor: "Ubiquiti Inc.",
        model: "UDM-Pro",
        display_name: "UniFi Dream Machine Pro (UDM-Pro)",
        category: "Router / Security Gateway",
        hostname: "unifi-udm-pro",
        os_details: "UniFi OS 4.0.20 (Debian 12 apt)",
        pkg_manager: "apt",
        lifecycle_tier: "active",
        trust_zone: "z0_core",
        reasoning: "Matched exact UDM-Pro identifier in Gold Hardware Catalog ($0.00 short-circuit)."
      },
      {
        pattern: /\b(UCG-ULTRA|CLOUD\s*GATEWAY\s*ULTRA)\b/i,
        vendor: "Ubiquiti Inc.",
        model: "UCG-Ultra",
        display_name: "UniFi Cloud Gateway Ultra (UCG-Ultra)",
        category: "Router / Security Gateway",
        hostname: "unifi-ucg-ultra",
        os_details: "UniFi OS 4.0.20 (Debian 12 apt)",
        pkg_manager: "apt",
        lifecycle_tier: "active",
        trust_zone: "z0_core",
        reasoning: "Matched exact UCG-Ultra identifier in Gold Hardware Catalog ($0.00 short-circuit)."
      },
      {
        pattern: /\b(USW-PRO-24-POE|USW-24-POE)\b/i,
        vendor: "Ubiquiti Inc.",
        model: "USW-Pro-24-PoE",
        display_name: "UniFi Switch Pro 24 PoE (USW-Pro-24-PoE)",
        category: "Managed PoE Switch",
        hostname: "unifi-usw-pro-24",
        os_details: "UniFi Switch Firmware 7.1.26",
        pkg_manager: "firmware",
        lifecycle_tier: "active",
        trust_zone: "z0_core",
        reasoning: "Matched exact USW-Pro-24-PoE switch identifier in Gold Hardware Catalog ($0.00 short-circuit)."
      },
      {
        pattern: /\b(U7-PRO|U6-PRO)\b/i,
        vendor: "Ubiquiti Inc.",
        model: "U7-Pro",
        display_name: "UniFi U7 Pro Wi-Fi 7 Access Point",
        category: "Wireless Access Point",
        hostname: "unifi-u7-pro-ap",
        os_details: "UniFi AP Firmware 7.0.66",
        pkg_manager: "firmware",
        lifecycle_tier: "active",
        trust_zone: "z0_core",
        reasoning: "Matched exact UniFi U7-Pro access point identifier in Gold Hardware Catalog ($0.00 short-circuit)."
      },
      {
        pattern: /\b(R7000|NIGHTHAWK\s*AC1900)\b/i,
        vendor: "Netgear",
        model: "R7000",
        display_name: "Netgear Nighthawk AC1900 (R7000)",
        category: "Wireless Router",
        hostname: "netgear-r7000",
        os_details: "Netgear Stock Firmware 1.0.11.136",
        pkg_manager: "firmware",
        lifecycle_tier: "legacy",
        trust_zone: "z2_lab",
        reasoning: "Matched Netgear Nighthawk R7000 identifier in Gold Hardware Catalog ($0.00 short-circuit)."
      },
      {
        pattern: /\b(SG300-10|SG300)\b/i,
        vendor: "Cisco",
        model: "SG300-10",
        display_name: "Cisco Small Business SG300-10 Managed Switch",
        category: "Managed Switch",
        hostname: "cisco-sg300-10",
        os_details: "Cisco SMB Firmware 1.4.11.5",
        pkg_manager: "firmware",
        lifecycle_tier: "legacy",
        trust_zone: "z2_lab",
        reasoning: "Matched Cisco SG300-10 managed switch identifier in Gold Hardware Catalog ($0.00 short-circuit)."
      },
      {
        pattern: /\b(SLZB-06\w*|SMLIGHT|ZBDONGLE\S*)\b/i,
        vendor: "SMLIGHT",
        model: "SLZB-06",
        display_name: "SMLIGHT SLZB-06 PoE Zigbee Coordinator",
        category: "IoT Coordinator",
        hostname: "slzb-06-zigbee",
        os_details: "SLZB-OS v2.3.6 / Home Assistant ZHA & Zigbee2MQTT",
        pkg_manager: "hacs",
        lifecycle_tier: "active",
        trust_zone: "z3_iot",
        reasoning: "Matched Zigbee Coordinator identifier in Gold Hardware Catalog ($0.00 short-circuit)."
      }
    ].freeze

    class << self
      def analyze(
        session_id:,
        turn_index: 1,
        client_platform: "unknown",
        device_id: "anonymous",
        network_site_id: nil,
        initial_mode: "photo_wizard",
        provider_override: "auto",
        previous_guess: nil,
        extracted_identifiers: [],
        user_clue_notes: [],
        images_base64: [],
        debug: false
      )
        start_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        normalized_clues = normalize_incoming_clues(extracted_identifiers, user_clue_notes)
        ephemeral_frames = Array(images_base64).compact.first(2)
        frame_kb_sizes = ephemeral_frames.map { |f| ((f.to_s.bytesize * 3.0 / 4.0) / 1024.0).round(1) }

        debug_trace = []
        elapsed_ms = -> { ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_monotonic) * 1000).round }
        trace = lambda do |stage, msg|
          debug_trace << "[+#{elapsed_ms.call}ms] [#{stage}] #{msg}"
        end

        trace.call(
          "INIT",
          "session=#{session_id} turn=#{turn_index} platform=#{client_platform} provider_override=#{provider_override} " \
          "frames=#{ephemeral_frames.size} (#{frame_kb_sizes.map { |k| "#{k}KB" }.join(', ').presence || '0KB'}) " \
          "clues=#{normalized_clues[:flat_list].inspect} debug=#{debug}"
        )

        result = nil
        raw_llm_response = nil
        usage = { input_tokens: 0, output_tokens: 0, cache_read_tokens: 0 }
        provider_used = "CatalogCache"
        model_used = "gold-short-circuit"
        fallback_used = false
        short_circuited = false

        begin
          # Step 1: $0.00 Gold Catalog & Confirmed Identifier Short-Circuit
          if %w[auto catalog].include?(provider_override.to_s.downcase)
            catalog_match = match_catalog_short_circuit(normalized_clues)
            if catalog_match
              if debug && ephemeral_frames.any? && provider_override.to_s.downcase != "catalog"
                trace.call(
                  "CATALOG_SHORT_CIRCUIT",
                  "Matched #{catalog_match['vendor']} #{catalog_match['model']} ($0.00 short-circuit), " \
                  "but bypassing short-circuit because debug=true and #{ephemeral_frames.size} image(s) were submitted."
                )
              else
                result = catalog_match
                short_circuited = true
                provider_used = "CatalogCache"
                model_used = "gold-short-circuit"
                trace.call(
                  "CATALOG_SHORT_CIRCUIT",
                  "HIT -> #{catalog_match['vendor']} #{catalog_match['model']} (#{catalog_match['reasoning']})"
                )
              end
            else
              trace.call(
                "CATALOG_SHORT_CIRCUIT",
                normalized_clues[:flat_list].empty? ? "SKIP (no prior text/barcode clues on turn #{turn_index})" : "MISS (no exact match in confirmed_hardware_identifiers.json or BUILT_IN_CATALOG_SIGNATURES)"
              )
            end
          end

          # Step 2: Upstream Vision LLM Router (Elastix Primary -> Gemini Failover)
          unless result
            if provider_override.to_s.downcase == "heuristic"
              trace.call("ROUTER", "Using deterministic Heuristic mode (provider_override=heuristic)")
              result = heuristic_infer(turn_index: turn_index, previous_guess: previous_guess, clues: normalized_clues)
              provider_used = "Heuristic"
              model_used = "heuristic-fallback"
            elsif provider_override.to_s.downcase == "gemini"
              trace.call("ROUTER", "Dispatching directly to GCP Gemini Interactions API (#{ENV.fetch('GEMINI_MODEL', 'gemini-3.8-flash')})")
              res_data = call_gemini_interactions(
                turn_index: turn_index,
                previous_guess: previous_guess,
                clues: normalized_clues,
                ephemeral_frames: ephemeral_frames
              )
              result = res_data[:result]
              raw_llm_response = res_data[:raw_text]
              usage = res_data[:usage]
              provider_used = "Google"
              model_used = res_data[:model]
              trace.call("LLM_OK", "Gemini #{model_used} responded (in=#{usage[:input_tokens]} out=#{usage[:output_tokens]} cached=#{usage[:cache_read_tokens]} tokens)")
            else
              begin
                trace.call("ROUTER", "Dispatching primary vision request to Elastix.ai (#{ENV.fetch('ELASTIX_MODEL', 'qwen3.8-27b')})")
                res_data = call_elastix_chat_completions(
                  session_id: session_id,
                  turn_index: turn_index,
                  previous_guess: previous_guess,
                  clues: normalized_clues,
                  ephemeral_frames: ephemeral_frames
                )
                result = res_data[:result]
                raw_llm_response = res_data[:raw_text]
                usage = res_data[:usage]
                provider_used = "Elastix"
                model_used = res_data[:model]
                elastix_top_conf = result["confidence"] || ((Array(result["candidates"]).first&.dig("confidencePercent") || 0).to_f / 100.0)
                elastix_multi_device = !!result["multipleDevicesDetected"]
                elastix_has_exact_id = %w[modelNumber serialNumber barcode].any? do |k|
                  result.dig("extractedIdentifiersObject", k).to_s.strip.present?
                end
                trace.call("LLM_OK", "Elastix #{model_used} responded (conf=#{(elastix_top_conf * 100).round}% multi_device=#{elastix_multi_device} in=#{usage[:input_tokens]} out=#{usage[:output_tokens]} cached=#{usage[:cache_read_tokens]} tokens)")

                # Escalate to GCP Gemini Flash when:
                # 1) Elastix confidence < 0.65 (e.g. rotated PCB stickers, embossed text), OR
                # 2) Multiple chassis are detected in frame without an exact label identifier (preventing peripheral familiarity bias)
                should_escalate = (elastix_top_conf < 0.65) || (elastix_multi_device && !elastix_has_exact_id)
                if should_escalate && ENV["GEMINI_API_KEY"].to_s.strip.present? && provider_override.to_s.downcase == "auto"
                  esc_reason = if elastix_multi_device && !elastix_has_exact_id && elastix_top_conf >= 0.65
                                 "multiple devices in frame without exact label identifier (conf=#{(elastix_top_conf * 100).round}%)"
                               else
                                 "Elastix top confidence #{(elastix_top_conf * 100).round}% < 65% threshold"
                               end
                  trace.call("LLM_ESCALATE", "#{esc_reason} -> escalating to GCP Gemini Flash")
                  begin
                    gem_data = call_gemini_interactions(
                      turn_index: turn_index,
                      previous_guess: result,
                      clues: normalized_clues,
                      ephemeral_frames: ephemeral_frames
                    )
                    gem_res = gem_data[:result]
                    gem_conf = gem_res["confidence"] || ((Array(gem_res["candidates"]).first&.dig("confidencePercent") || 0).to_f / 100.0)
                    usage = {
                      input_tokens: usage[:input_tokens].to_i + gem_data[:usage][:input_tokens].to_i,
                      output_tokens: usage[:output_tokens].to_i + gem_data[:usage][:output_tokens].to_i,
                      cache_read_tokens: usage[:cache_read_tokens].to_i + gem_data[:usage][:cache_read_tokens].to_i
                    }
                    fallback_used = true
                    if (elastix_multi_device && !elastix_has_exact_id) || gem_conf >= elastix_top_conf
                      result = gem_res
                      result["multipleDevicesDetected"] = true if elastix_multi_device
                      result["multiDeviceWarning"] ||= MULTI_DEVICE_WARNING_MESSAGE if result["multipleDevicesDetected"]
                      raw_llm_response = gem_data[:raw_text]
                      provider_used = "Google"
                      model_used = gem_data[:model]
                      trace.call("LLM_OK", "Gemini escalation #{model_used} selected (conf=#{(gem_conf * 100).round}% multi_device=#{result['multipleDevicesDetected']})")
                    else
                      trace.call("LLM_OK", "Gemini escalation returned #{(gem_conf * 100).round}%; retaining Elastix result (#{(elastix_top_conf * 100).round}%)")
                    end
                  rescue StandardError => esc_err
                    trace.call("LLM_WARN", "Gemini escalation skipped (#{esc_err.message}); retaining Elastix result")
                  end
                end
              rescue StandardError => elastix_err
                Rails.logger.warn("[Discovery::HardwareVisionService] Elastix primary failed (#{elastix_err.message}); failing over to Gemini")
                trace.call("LLM_WARN", "Elastix primary failed: #{elastix_err.message} -> failing over to GCP Gemini")
                fallback_used = true
                begin
                  res_data = call_gemini_interactions(
                    turn_index: turn_index,
                    previous_guess: previous_guess,
                    clues: normalized_clues,
                    ephemeral_frames: ephemeral_frames
                  )
                  result = res_data[:result]
                  raw_llm_response = res_data[:raw_text]
                  usage = res_data[:usage]
                  provider_used = "Google"
                  model_used = res_data[:model]
                  trace.call("LLM_OK", "Gemini failover #{model_used} responded (in=#{usage[:input_tokens]} out=#{usage[:output_tokens]} cached=#{usage[:cache_read_tokens]} tokens)")
                rescue StandardError => gemini_err
                  Rails.logger.warn("[Discovery::HardwareVisionService] Gemini failover failed (#{gemini_err.message}); using deterministic heuristic")
                  trace.call("LLM_ERROR", "Gemini failover failed: #{gemini_err.message} -> falling back to Heuristic")
                  result = heuristic_infer(turn_index: turn_index, previous_guess: previous_guess, clues: normalized_clues)
                  provider_used = "Heuristic"
                  model_used = "heuristic-fallback"
                end
              end
            end
          end
        ensure
          # PRIVACY COMPLIANCE INVARIANT: Explicitly wipe Base64 image references from RAM
          ephemeral_frames.clear
        end

        raw_candidates_summary = Array(result["candidates"]).map.with_index(1) do |c, i|
          "##{i} #{c['manufacturer']} #{c['modelNumber']} (#{c['confidencePercent']}%)"
        end.join(", ")
        trace.call(
          "LLM_PARSE",
          "Extracted #{Array(result['candidates']).size} candidate(s): [#{raw_candidates_summary}] | identifiers=#{JSON.generate(result['extractedIdentifiersObject'] || normalized_clues[:object])}"
        )

        # Step 3: Audit every candidate against the Gold Datalake (canonical_feeds, catalog_releases, confirmed_identifiers)
        audited_candidates = audit_candidates_against_gold_datalake(Array(result["candidates"]), trace: trace)
        result["candidates"] = audited_candidates

        latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_monotonic) * 1000).round
        top_candidate = audited_candidates.first || {}
        top_vendor = result["vendor"] || top_candidate["manufacturer"] || "Unknown Vendor"
        top_model = result["model"] || top_candidate["modelNumber"] || "Unidentified Hardware"
        top_confidence = result["confidence"] || ((top_candidate["confidencePercent"] || 65).to_f / 100.0)
        top_alignment = top_candidate["goldAlignment"] || {}
        top_gold_status = top_alignment["statusLabel"] || "UNALIGNED RAW MATCH"
        top_feed_slug = top_alignment["matchedFeedSlug"]
        short_circuit_source = short_circuited ? (result["shortCircuitSource"] || "catalog") : nil
        routing_tier = if short_circuited
                         "tier1_short_circuit"
                       elsif model_used.to_s == "heuristic-fallback"
                         "tier3_heuristic"
                       elsif fallback_used
                         "tier2_gemini_failover"
                       else
                         "tier2_elastix_vision"
                       end

        candidates_snapshot = audited_candidates.map.with_index do |c, idx|
          ga = c["goldAlignment"] || {}
          {
            "rank" => idx,
            "manufacturer" => c["manufacturer"],
            "modelNumber" => c["modelNumber"],
            "displayName" => c["displayName"],
            "deviceCategory" => c["deviceCategory"],
            "confidencePercent" => c["confidencePercent"],
            "goldAlignmentStatus" => ga["statusLabel"],
            "matchedFeedSlug" => ga["matchedFeedSlug"],
            "inferredPurl" => ga["inferredPurl"]
          }
        end

        telemetry_record = Telemetry::HostedAiLogger.log_ai_call(
          feature: "hardware_discovery",
          provider: provider_used,
          model: model_used,
          status: "success",
          client_platform: client_platform,
          device_id: device_id,
          session_id: session_id,
          turn_index: turn_index,
          routing_tier: routing_tier,
          short_circuit_source: short_circuit_source,
          image_count: frame_kb_sizes.size,
          image_kb_total: frame_kb_sizes.sum,
          fallback_used: fallback_used,
          short_circuited: short_circuited,
          latency_ms: latency_ms,
          input_tokens: usage[:input_tokens],
          output_tokens: usage[:output_tokens],
          cache_read_tokens: usage[:cache_read_tokens],
          confidence: top_confidence,
          inferred_vendor: top_vendor,
          inferred_model: top_model,
          gold_alignment_status: top_gold_status,
          matched_feed_slug: top_feed_slug,
          candidate_count: audited_candidates.size,
          candidates_snapshot: candidates_snapshot,
          extracted_identifiers: normalized_clues[:flat_list],
          user_clue_notes: Array(user_clue_notes)
        )

        provider_label = if short_circuited
                           "Tuesday Server (Catalog $0 Short-Circuit • #{latency_ms}ms)"
                         else
                           "Tuesday Server → #{provider_used} (#{model_used} • #{(latency_ms / 1000.0).round(2)}s)"
                         end

        next_prompt = result["nextPromptForUser"] || result["nextNarrowingQuestion"] || "Can you check for a Barcode, Serial Number, Model, or MAC Address on the label?"
        image_quality_score = (result["imageQualityScore"] || (top_confidence >= 0.50 ? 0.85 : 0.40)).to_f.round(2)
        discovery_status = if top_confidence >= 0.85
                             "matched_exact"
                           elsif image_quality_score < 0.45
                             "coach_retake"
                           else
                             "coach_next_angle"
                           end

        persist_discovery_turn_telemetry!(
          session_id: session_id,
          turn_index: turn_index,
          network_site_id: network_site_id,
          client_platform: client_platform,
          device_id: device_id,
          initial_mode: initial_mode,
          image_count: frame_kb_sizes.size,
          image_kb_total: frame_kb_sizes.sum,
          routing_tier: routing_tier,
          short_circuit_source: short_circuit_source,
          provider: provider_used,
          model: model_used,
          short_circuited: short_circuited,
          fallback_used: fallback_used,
          latency_ms: latency_ms,
          usage: usage,
          top_vendor: top_vendor,
          top_model: top_model,
          top_confidence: top_confidence,
          discovery_status: discovery_status,
          gold_alignment_status: top_gold_status,
          matched_feed_slug: top_feed_slug,
          extracted_identifiers_obj: result["extractedIdentifiersObject"] || normalized_clues[:object],
          extracted_identifiers_flat: normalized_clues[:flat_list],
          user_clue_notes: Array(user_clue_notes),
          previous_guess: previous_guess,
          candidates_snapshot: candidates_snapshot,
          next_narrowing_question: next_prompt
        )

        coaching_directive = {
          "status" => discovery_status,
          "imageQualityScore" => image_quality_score,
          "nextPhotoPrompt" => discovery_status == "matched_exact" ? nil : next_prompt
        }

        debug_log_text = format_debug_log_text(
          session_id: session_id,
          turn_index: turn_index,
          client_platform: client_platform,
          provider_used: provider_used,
          model_used: model_used,
          latency_ms: latency_ms,
          cost_usd: telemetry_record["costUSD"],
          usage: usage,
          visual_summary: result["visualSummary"],
          extracted_identifiers: result["extractedIdentifiersObject"] || normalized_clues[:object],
          candidates: audited_candidates,
          raw_llm_response: raw_llm_response,
          debug_trace: debug_trace
        )

        livetail_entry = {
          "timestamp" => Time.now.utc.iso8601(3),
          "sessionId" => session_id,
          "turnIndex" => turn_index,
          "clientPlatform" => client_platform,
          "deviceId" => device_id,
          "debugEnabled" => !!debug,
          "frameCount" => frame_kb_sizes.size,
          "frameSizesKb" => frame_kb_sizes,
          "providerUsed" => provider_used,
          "modelUsed" => model_used,
          "fallbackUsed" => fallback_used,
          "shortCircuited" => short_circuited,
          "latencyMs" => latency_ms,
          "costUSD" => telemetry_record["costUSD"],
          "inputTokens" => usage[:input_tokens],
          "outputTokens" => usage[:output_tokens],
          "visualSummary" => result["visualSummary"],
          "extractedIdentifiers" => result["extractedIdentifiersObject"] || normalized_clues[:object],
          "candidates" => audited_candidates,
          "rawLlmResponse" => raw_llm_response,
          "debugTrace" => debug_trace,
          "debugLogText" => debug_log_text
        }
        Telemetry::HostedAiLogger.write_debug_livetail(livetail_entry, formatted_text: debug_log_text)

        {
          # Mobile rich turn fields (Android & iOS)
          "visualSummary" => result["visualSummary"] || result["reasoning"] || "Analyzed device hardware and clues.",
          "nextNarrowingQuestion" => next_prompt,
          "recommendedClueTypes" => result["recommendedClueTypes"] || DEFAULT_CLUE_TYPES,
          "extractedIdentifiersObject" => result["extractedIdentifiersObject"] || normalized_clues[:object],
          "extractedIdentifiers" => normalized_clues[:flat_list],
          "multipleDevicesDetected" => !!result["multipleDevicesDetected"],
          "multiDeviceWarning" => result["multiDeviceWarning"],
          "candidates" => audited_candidates,
          # Top-level summary, coaching & telemetry fields
          "vendor" => top_vendor,
          "model" => top_model,
          "confidence" => top_confidence.round(2),
          "discoveryStatus" => discovery_status,
          "coachingDirective" => coaching_directive,
          "reasoning" => result["reasoning"] || top_candidate["reasoning"] || result["visualSummary"],
          "nextPromptForUser" => next_prompt,
          "suggestedLifecycleTier" => result["suggestedLifecycleTier"] || "active",
          "suggestedTrustZone" => result["suggestedTrustZone"] || "z1_trusted",
          "providerUsed" => provider_used,
          "providerLabel" => provider_label,
          "modelUsed" => model_used,
          "fallbackUsed" => fallback_used,
          "shortCircuited" => short_circuited,
          "latencyMs" => latency_ms,
          "costUSD" => telemetry_record["costUSD"],
          "debugTrace" => debug_trace,
          "rawLlmResponse" => raw_llm_response,
          "debugLogText" => debug_log_text,
          "privacyAttestation" => PRIVACY_ATTESTATION
        }
      end

      def record_confirmation!(
        session_id:,
        client_platform: "unknown",
        device_id: "anonymous",
        network_site_id: nil,
        monitored_device_id: nil,
        inferred_vendor: nil,
        inferred_model: nil,
        confirmed_vendor: nil,
        confirmed_model: nil,
        was_edited: false,
        resolution_status: "confirmed_candidate",
        selected_candidate_rank: 0,
        initial_mode: "photo_wizard",
        final_mode: nil,
        extracted_identifiers: [],
        user_clue_notes: [],
        suggested_lifecycle_tier: "active",
        suggested_trust_zone: "z1_trusted"
      )
        clean_identifiers = Array(extracted_identifiers).map(&:to_s).map(&:strip).reject(&:empty?).uniq
        clean_clues = Array(user_clue_notes).map(&:to_s).map(&:strip).reject(&:empty?).uniq
        norm_status = DiscoverySession::VALID_RESOLUTION_STATUSES.include?(resolution_status.to_s) ? resolution_status.to_s : "confirmed_candidate"
        resolved_final_mode = final_mode.presence || (case norm_status
                                                      when "pivoted_to_barcode" then "barcode_scan"
                                                      when "pivoted_to_manual" then "manual_agent"
                                                      else initial_mode.presence || "photo_wizard"
                                                      end)

        # Never assume a user's candidate pick is verified ground truth. We are not training a model
        # or auto-mutating the Gold Confirmed Catalog from unverified user taps. Instead, log what the
        # user selected as observational product telemetry and aggregate pick frequency analytics.
        session_row = persist_discovery_resolution_telemetry!(
          session_id: session_id,
          network_site_id: network_site_id,
          monitored_device_id: monitored_device_id,
          client_platform: client_platform,
          device_id: device_id,
          initial_mode: initial_mode,
          final_mode: resolved_final_mode,
          resolution_status: norm_status,
          selected_candidate_rank: selected_candidate_rank,
          was_edited: was_edited,
          inferred_vendor: inferred_vendor,
          inferred_model: inferred_model,
          confirmed_vendor: confirmed_vendor,
          confirmed_model: confirmed_model,
          extracted_identifiers: clean_identifiers,
          user_clue_notes: clean_clues
        )

        Telemetry::HostedAiLogger.log_confirmation(
          session_id: session_id,
          client_platform: client_platform,
          device_id: device_id,
          inferred_vendor: session_row&.inferred_vendor || inferred_vendor,
          inferred_model: session_row&.inferred_model || inferred_model,
          confirmed_vendor: confirmed_vendor.to_s,
          confirmed_model: confirmed_model.to_s,
          was_edited: was_edited,
          resolution_status: norm_status,
          selected_candidate_rank: selected_candidate_rank,
          initial_mode: session_row&.initial_mode || initial_mode,
          final_mode: resolved_final_mode,
          turns_count: session_row&.turns_count || 1,
          total_llm_turns: session_row&.total_llm_turns || 0,
          total_tokens: session_row&.total_tokens || 0,
          total_latency_ms: session_row&.total_latency_ms || 0,
          gold_alignment_status: session_row&.gold_alignment_status,
          needs_catalog_review: session_row ? session_row.needs_catalog_review : (norm_status != "confirmed_candidate" || was_edited),
          extracted_identifiers: clean_identifiers,
          user_clue_notes: clean_clues
        )
      end

      def resolve_gold_device_identity(vendor:, model:, version: "1.0.0")
        audited = audit_candidates_against_gold_datalake([
          {
            "manufacturer" => vendor.to_s,
            "modelNumber" => model.to_s,
            "displayName" => "#{vendor} #{model}".strip,
            "suggestedOsDetails" => ""
          }
        ]).first || {}

        alignment = audited["goldAlignment"] || {}
        primary_purl_base = alignment["inferredPurl"].presence || infer_candidate_purl(vendor: vendor.to_s, model: model.to_s)
        ver = version.presence || "1.0.0"

        purls = ["#{primary_purl_base}@#{ver}"]

        # Also include slash-variant PURLs (e.g. "MB7420 / MB7621 / MB8600" -> mb7420, mb7621, mb8600)
        # so multi-model family picks match bulletins on any member SKU in that family.
        idx_map = confirmed_catalog_index
        vendor_slug = vendor.to_s.split(/\s*\/\s*/).first.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "").presence || "generic"
        extract_candidate_model_slugs(model.to_s).each do |c_slug|
          matched = idx_map[:by_purl]["pkg:generic/#{vendor_slug}/#{c_slug}"] ||
                    (c_slug.length >= 3 && idx_map[:by_model_slug][c_slug])
          if matched && matched["canonical_purl"].present?
            purls << "#{matched['canonical_purl']}@#{ver}"
          end
        end

        {
          purls: purls.uniq,
          category_code: alignment["categoryCode"].presence || "C8",
          matched_feed_slug: alignment["matchedFeedSlug"],
          aligned: !!alignment["aligned"]
        }
      end

      CATEGORY_CODE_LABELS = {
        "C1" => "C1 • Power / UPS",
        "C2" => "C2 • WAN / Modem",
        "C3" => "C3 • Gateway / Router",
        "C4" => "C4 • Core Switch",
        "C5" => "C5 • Patch Panel",
        "C6" => "C6 • Compute / NAS",
        "C7" => "C7 • Wireless AP",
        "C8" => "C8 • IoT / Hub / Misc"
      }.freeze

      def match_catalog_short_circuit(normalized_clues)
        flat_list = normalized_clues[:flat_list]
        return nil if flat_list.empty?

        joined = flat_list.join(" | ")
        idx = confirmed_catalog_index

        # 1a. Exact Barcode / UPC / GTIN O(1) lookup against 7,122+ Gold Catalog SKUs
        barcode_candidates = []
        barcode_candidates << normalized_clues.dig(:object, "barcode").to_s.gsub(/[^0-9]/, "")
        flat_list.each do |item|
          item.to_s.scan(/\b(\d{8,14})\b/).flatten.each { |digits| barcode_candidates << digits }
        end
        barcode_candidates.reject(&:empty?).uniq.each do |upc|
          entry = idx[:by_upc][upc]
          next unless entry

          cat_label = CATEGORY_CODE_LABELS[entry["category_code"]] || "Verified Network / IoT Hardware"
          model_display = entry["model"].to_s.upcase
          return build_catalog_turn_payload(
            vendor: entry["vendor"],
            model: model_display,
            display_name: "#{entry['brand'] || entry['vendor']} #{model_display}",
            category: cat_label,
            hostname: "#{entry['vendor'].to_s.downcase.gsub(/[^a-z0-9]+/, '-')}-#{entry['model'].to_s.downcase.gsub(/[^a-z0-9]+/, '-')}",
            os_details: "Verified Tuesday Gold Catalog SKU (#{entry['canonical_purl']})",
            pkg_manager: "firmware",
            confidence_pct: 99,
            reasoning: "Matched exact UPC/GTIN barcode (#{upc}) to #{entry['vendor']} #{model_display} in Gold Hardware Catalog (0 LLM turns).",
            lifecycle_tier: entry["lifecycle_tier"] || "active",
            trust_zone: entry["trust_zone"] || "z1_trusted",
            clues: normalized_clues,
            short_circuit_source: "upc_gtin"
          )
        end

        # 1b. FCC OET Regulatory ID & Grantee Prefix O(1) Lookup (0 LLM turns)
        fcc_candidates = []
        fcc_candidates << normalized_clues.dig(:object, "fccId").to_s.strip
        flat_list.each do |item|
          item.to_s.scan(/\b(?:FCC\s*ID\s*[:#\-]?\s*)?([A-Z0-9]{3,5}-[A-Z0-9\-_]{2,14}|(?:SWX|PY3|MSQ|TE7|TVE|I88|KA2|Q87|WR9|BCG|A3L|NKR|BEJ|LDK|UID|IHD|SBV|JPZ)[A-Z0-9]{4,14})\b/i).flatten.each do |fid|
            fcc_candidates << fid
          end
        end
        contains_modular_hint = joined.match?(/\bcontains\s+fcc\s*id\b/i)

        fcc_candidates.reject(&:empty?).uniq.each do |raw_fcc|
          norm_fcc = raw_fcc.upcase.gsub(/[^A-Z0-9]/, "")
          next if norm_fcc.length < 5

          grantee_prefix = idx[:fcc_grantees].keys.find { |g| norm_fcc.start_with?(g) }
          grantee_info = grantee_prefix && idx[:fcc_grantees][grantee_prefix]

          # If this is an embedded radio SoC module ("Contains FCC ID:" or RADIO_MODULE grantee like 2AC7Z Espressif),
          # enrich the clues with the exact radio module architecture rather than mistaking the chip vendor for the outer chassis brand.
          if grantee_info && (grantee_info["type"] == "RADIO_MODULE" || contains_modular_hint)
            module_note = "Embedded Radio Module (FCC #{raw_fcc.upcase}): #{grantee_info['notes']}"
            normalized_clues[:flat_list] << module_note unless normalized_clues[:flat_list].include?(module_note)
            next
          end

          entry = idx[:by_fcc_id][norm_fcc]
          sc_source = "fcc_id"
          if entry.nil? && grantee_prefix && grantee_info && grantee_info["type"] == "HOST_DEVICE"
            prod_suffix = norm_fcc.sub(/\A#{Regexp.escape(grantee_prefix)}/, "").downcase
            if prod_suffix.length >= 3 && idx[:by_model_slug][prod_suffix]
              entry = idx[:by_model_slug][prod_suffix]
              sc_source = "fcc_grantee_suffix"
            end
          end
          next unless entry

          normalized_clues[:object]["fccId"] ||= entry["fcc_id"] || raw_fcc.upcase
          cat_label = CATEGORY_CODE_LABELS[entry["category_code"]] || "Verified Network / IoT Hardware"
          model_display = entry["model"].to_s.upcase
          return build_catalog_turn_payload(
            vendor: entry["vendor"],
            model: model_display,
            display_name: "#{entry['brand'] || entry['vendor']} #{model_display}",
            category: cat_label,
            hostname: "#{entry['vendor'].to_s.downcase.gsub(/[^a-z0-9]+/, '-')}-#{entry['model'].to_s.downcase.gsub(/[^a-z0-9]+/, '-')}",
            os_details: "Verified Tuesday Gold Catalog FCC Grant (#{entry['fcc_id'] || raw_fcc.upcase} • #{entry['canonical_purl']})",
            pkg_manager: "firmware",
            confidence_pct: 99,
            reasoning: "Matched FCC OET Equipment Grant (#{entry['fcc_id'] || raw_fcc.upcase}) to #{entry['vendor']} #{model_display} in Gold Hardware Catalog (0 LLM turns).",
            lifecycle_tier: entry["lifecycle_tier"] || "active",
            trust_zone: entry["trust_zone"] || "z1_trusted",
            clues: normalized_clues,
            short_circuit_source: sc_source
          )
        end

        # 1c. Exact user-confirmed identifier lookup
        token_candidates = []
        token_candidates << normalized_clues.dig(:object, "modelNumber").to_s.strip
        flat_list.each do |raw|
          cleaned = raw.to_s.sub(/\A(Barcode|FCC(\s*ID)?|Serial(\s*Number)?|QR(\s*Code)?|Model(\s*Number)?|MAC(\s*Address)?|Clue):\s*/i, "").strip
          token_candidates << cleaned
        end

        token_candidates.reject { |t| t.length < 4 }.uniq.each do |token|
          entry = idx[:by_identifier][token.downcase]
          next unless entry

          cat_label = CATEGORY_CODE_LABELS[entry["category_code"]] || "Verified Network / IoT Hardware"
          model_display = entry["model"].to_s
          return build_catalog_turn_payload(
            vendor: entry["vendor"],
            model: model_display,
            display_name: "#{entry['brand'] || entry['vendor']} #{model_display}",
            category: cat_label,
            hostname: entry["model"].to_s.downcase.gsub(/[^a-z0-9]+/, "-"),
            os_details: "Verified Tuesday Gold Catalog Device (#{entry['canonical_purl']})",
            pkg_manager: "firmware",
            confidence_pct: 98,
            reasoning: "Matched verified hardware identifier (#{token}) in Gold Confirmed Catalog (0 LLM turns).",
            lifecycle_tier: entry["lifecycle_tier"] || "active",
            trust_zone: entry["trust_zone"] || "z1_trusted",
            clues: normalized_clues,
            short_circuit_source: "confirmed_identifier"
          )
        end

        # 2. Check built-in Gold Catalog hardware patterns
        BUILT_IN_CATALOG_SIGNATURES.each do |sig|
          if joined.match?(sig[:pattern])
            return build_catalog_turn_payload(
              vendor: sig[:vendor],
              model: sig[:model],
              display_name: sig[:display_name],
              category: sig[:category],
              hostname: sig[:hostname],
              os_details: sig[:os_details],
              pkg_manager: sig[:pkg_manager],
              confidence_pct: 96,
              reasoning: sig[:reasoning],
              lifecycle_tier: sig[:lifecycle_tier],
              trust_zone: sig[:trust_zone],
              clues: normalized_clues,
              short_circuit_source: "built_in_signature"
            )
          end
        end

        # 3. Check 7,161+ Gold Catalog SKU model_slug index
        token_candidates.reject { |t| t.length < 4 }.uniq.each do |token|
          slug = token.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
          next if slug.length < 4

          entry = idx[:by_model_slug][slug]
          next unless entry

          cat_label = CATEGORY_CODE_LABELS[entry["category_code"]] || "Verified Network / IoT Hardware"
          model_display = entry["model"].to_s
          return build_catalog_turn_payload(
            vendor: entry["vendor"],
            model: model_display,
            display_name: "#{entry['brand'] || entry['vendor']} #{model_display}",
            category: cat_label,
            hostname: entry["model"].to_s.downcase.gsub(/[^a-z0-9]+/, "-"),
            os_details: "Verified Tuesday Gold Catalog Device (#{entry['canonical_purl']})",
            pkg_manager: "firmware",
            confidence_pct: 98,
            reasoning: "Matched verified hardware identifier (#{token}) in Gold Confirmed Catalog (0 LLM turns).",
            lifecycle_tier: entry["lifecycle_tier"] || "active",
            trust_zone: entry["trust_zone"] || "z1_trusted",
            clues: normalized_clues,
            short_circuit_source: "model_slug"
          )
        end

        nil
      end

      private

      def normalize_incoming_clues(extracted_identifiers, user_clue_notes)
        obj = {
          "barcode" => nil,
          "fccId" => nil,
          "serialNumber" => nil,
          "qrCode" => nil,
          "modelNumber" => nil,
          "macAddress" => nil
        }
        flat = []

        if extracted_identifiers.is_a?(Hash) || (defined?(ActionController::Parameters) && extracted_identifiers.is_a?(ActionController::Parameters))
          h = extracted_identifiers.respond_to?(:to_unsafe_h) ? extracted_identifiers.to_unsafe_h : extracted_identifiers
          obj["barcode"] = h["barcode"].presence
          obj["fccId"] = h["fccId"].presence || h["fcc_id"].presence
          obj["serialNumber"] = h["serialNumber"].presence || h["serial_number"].presence
          obj["qrCode"] = h["qrCode"].presence || h["qr_code"].presence
          obj["modelNumber"] = h["modelNumber"].presence || h["model_number"].presence
          obj["macAddress"] = h["macAddress"].presence || h["mac_address"].presence
          obj.each { |k, v| flat << "#{k}: #{v}" if v.present? }
        else
          Array(extracted_identifiers).each do |item|
            s = item.to_s.strip
            next if s.empty?

            flat << s
            obj["barcode"] ||= s.sub(/\ABarcode:\s*/i, "") if s.match?(/\ABarcode:/i)
            obj["fccId"] ||= s.sub(/\A(?:Contains\s+)?FCC(\s*ID)?:\s*/i, "") if s.match?(/\A(?:Contains\s+)?FCC/i)
            obj["serialNumber"] ||= s.sub(/\ASerial(\s*Number)?:\s*/i, "") if s.match?(/\ASerial/i)
            obj["qrCode"] ||= s.sub(/\AQR(\s*Code)?:\s*/i, "") if s.match?(/\AQR/i)
            obj["modelNumber"] ||= s.sub(/\AModel(\s*Number)?:\s*/i, "") if s.match?(/\AModel/i)
            obj["macAddress"] ||= s.sub(/\AMAC(\s*Address)?:\s*/i, "") if s.match?(/\AMAC/i)
          end
        end

        Array(user_clue_notes).each do |note|
          s = note.to_s.strip
          next if s.empty?

          flat << "Clue: #{s}"
          if obj["fccId"].nil? && (m = s.match(/\bFCC\s*ID\s*[:#\-]?\s*([A-Z0-9]{3,5}-?[A-Z0-9\-_]{2,14})\b/i))
            obj["fccId"] = m[1]
          end
        end

        if obj["fccId"].present?
          norm_fcc = obj["fccId"].to_s.upcase.gsub(/[^A-Z0-9]/, "")
          grantees = confirmed_catalog_index[:fcc_grantees] || {}
          grantee_prefix = grantees.keys.find { |g| norm_fcc.start_with?(g) }
          grantee_info = grantee_prefix && grantees[grantee_prefix]
          contains_hint = flat.any? { |c| c.match?(/\bcontains\s+fcc\s*id\b/i) }
          if grantee_info && (grantee_info["type"] == "RADIO_MODULE" || contains_hint)
            flat << "Embedded Radio Module (FCC #{obj['fccId'].upcase}): #{grantee_info['notes']}"
          end
        end

        { object: obj, flat_list: flat.uniq }
      end

      def build_catalog_turn_payload(vendor:, model:, display_name:, category:, hostname:, os_details:, pkg_manager:, confidence_pct:, reasoning:, lifecycle_tier:, trust_zone:, clues:, short_circuit_source: "catalog")
        obj = clues[:object].dup
        obj["modelNumber"] ||= model
        {
          "visualSummary" => reasoning,
          "nextNarrowingQuestion" => "Identifier verified in Tuesday Gold Catalog (#{display_name}). Confirm match below or add additional clues.",
          "recommendedClueTypes" => DEFAULT_CLUE_TYPES,
          "extractedIdentifiersObject" => obj,
          "shortCircuitSource" => short_circuit_source,
          "candidates" => [
            {
              "manufacturer" => vendor,
              "modelNumber" => model,
              "displayName" => display_name,
              "deviceCategory" => category,
              "confidencePercent" => confidence_pct,
              "reasoning" => reasoning,
              "suggestedHostname" => hostname,
              "suggestedOsDetails" => os_details,
              "suggestedPackageManager" => pkg_manager
            }
          ],
          "vendor" => vendor,
          "model" => model,
          "confidence" => (confidence_pct / 100.0).round(2),
          "reasoning" => reasoning,
          "nextPromptForUser" => nil,
          "suggestedLifecycleTier" => lifecycle_tier,
          "suggestedTrustZone" => trust_zone
        }
      end

      def persist_discovery_turn_telemetry!(
        session_id:,
        turn_index:,
        network_site_id:,
        client_platform:,
        device_id:,
        initial_mode:,
        image_count:,
        image_kb_total:,
        routing_tier:,
        short_circuit_source:,
        provider:,
        model:,
        short_circuited:,
        fallback_used:,
        latency_ms:,
        usage:,
        top_vendor:,
        top_model:,
        top_confidence:,
        discovery_status:,
        gold_alignment_status:,
        matched_feed_slug:,
        extracted_identifiers_obj:,
        extracted_identifiers_flat:,
        user_clue_notes:,
        previous_guess:,
        candidates_snapshot:,
        next_narrowing_question:
      )
        return nil unless defined?(DiscoverySession) && DiscoverySession.table_exists?

        norm_mode = DiscoverySession::VALID_MODES.include?(initial_mode.to_s) ? initial_mode.to_s : "photo_wizard"
        session = DiscoverySession.find_or_initialize_by(session_id: session_id.to_s)
        if session.new_record?
          session.network_site_id = network_site_id
          session.client_platform = client_platform.to_s
          session.device_id = device_id.to_s
          session.initial_mode = norm_mode
          session.final_mode = norm_mode
          session.resolution_status = "in_progress"
        elsif network_site_id.present? && session.network_site_id.nil?
          session.network_site_id = network_site_id
        end

        turn_tokens = usage[:input_tokens].to_i + usage[:output_tokens].to_i + usage[:cache_read_tokens].to_i
        session.turns_count = [session.turns_count.to_i + 1, turn_index.to_i].max
        session.total_photos_submitted = session.total_photos_submitted.to_i + image_count.to_i
        session.total_clues_submitted = [session.total_clues_submitted.to_i, Array(user_clue_notes).size].max
        if short_circuited
          session.short_circuited_turns = session.short_circuited_turns.to_i + 1
        elsif routing_tier != "tier3_heuristic"
          session.total_llm_turns = session.total_llm_turns.to_i + 1
        end
        session.total_tokens = session.total_tokens.to_i + turn_tokens
        session.total_latency_ms = session.total_latency_ms.to_i + latency_ms.to_i
        session.inferred_vendor = top_vendor
        session.inferred_model = top_model
        session.top_confidence = top_confidence
        session.gold_alignment_status = gold_alignment_status
        session.matched_feed_slug = matched_feed_slug
        session.extracted_identifiers_list = (session.extracted_identifiers_list + Array(extracted_identifiers_flat)).uniq
        session.user_clue_notes_list = (session.user_clue_notes_list + Array(user_clue_notes)).uniq
        session.needs_catalog_review = (gold_alignment_status != "GOLD ALIGNED")
        session.save!

        turn = session.discovery_turns.create!(
          session_id: session.session_id,
          turn_index: turn_index.to_i,
          image_count: image_count.to_i,
          image_kb_total: image_kb_total.to_f.round(1),
          routing_tier: routing_tier,
          short_circuit_source: short_circuit_source,
          provider: provider.to_s,
          model: model.to_s,
          short_circuited: !!short_circuited,
          fallback_used: !!fallback_used,
          latency_ms: latency_ms.to_i,
          input_tokens: usage[:input_tokens].to_i,
          output_tokens: usage[:output_tokens].to_i,
          cache_read_tokens: usage[:cache_read_tokens].to_i,
          top_vendor: top_vendor,
          top_model: top_model,
          top_confidence: top_confidence,
          discovery_status: discovery_status,
          gold_alignment_status: gold_alignment_status,
          candidate_count: Array(candidates_snapshot).size,
          extracted_identifiers_object: extracted_identifiers_obj || {},
          user_clue_notes_list: Array(user_clue_notes),
          previous_guess_object: previous_guess || {},
          candidates_list: Array(candidates_snapshot),
          next_narrowing_question: next_narrowing_question
        )

        if defined?(ProductTelemetryEvent) && ProductTelemetryEvent.table_exists?
          ProductTelemetryEvent.create!(
            event_name: "discovery.turn_completed",
            event_domain: "discovery",
            network_site_id: session.network_site_id,
            client_platform: client_platform.to_s,
            device_id: device_id.to_s,
            session_id: session.session_id,
            target_entity_type: "DiscoverySession",
            target_entity_id: session.session_id,
            latency_ms: latency_ms.to_i,
            llm_turns: short_circuited || routing_tier == "tier3_heuristic" ? 0 : 1,
            total_tokens: turn_tokens,
            properties: {
              turnIndex: turn_index.to_i,
              routingTier: routing_tier,
              shortCircuitSource: short_circuit_source,
              imageCount: image_count.to_i,
              userClueCount: Array(user_clue_notes).size,
              topVendor: top_vendor,
              topModel: top_model,
              topConfidence: top_confidence,
              goldAlignmentStatus: gold_alignment_status,
              candidateCount: Array(candidates_snapshot).size
            }
          )
        end

        turn
      rescue StandardError => e
        Rails.logger.warn("[Discovery::HardwareVisionService] Turn telemetry DB write skipped: #{e.message}")
        nil
      end

      def persist_discovery_resolution_telemetry!(
        session_id:,
        network_site_id:,
        monitored_device_id:,
        client_platform:,
        device_id:,
        initial_mode:,
        final_mode:,
        resolution_status:,
        selected_candidate_rank:,
        was_edited:,
        inferred_vendor:,
        inferred_model:,
        confirmed_vendor:,
        confirmed_model:,
        extracted_identifiers:,
        user_clue_notes:
      )
        return nil unless defined?(DiscoverySession) && DiscoverySession.table_exists?

        norm_init = DiscoverySession::VALID_MODES.include?(initial_mode.to_s) ? initial_mode.to_s : "photo_wizard"
        norm_final = DiscoverySession::VALID_MODES.include?(final_mode.to_s) ? final_mode.to_s : norm_init
        session = DiscoverySession.find_or_initialize_by(session_id: session_id.to_s)
        if session.new_record?
          session.client_platform = client_platform.to_s
          session.device_id = device_id.to_s
          session.initial_mode = norm_init
        end
        session.network_site_id ||= network_site_id
        session.monitored_device_id = monitored_device_id if monitored_device_id.present?
        session.final_mode = norm_final
        session.resolution_status = resolution_status
        session.selected_candidate_rank = selected_candidate_rank
        session.was_edited = !!was_edited
        session.inferred_vendor = inferred_vendor if inferred_vendor.present?
        session.inferred_model = inferred_model if inferred_model.present?
        session.confirmed_vendor = confirmed_vendor if confirmed_vendor.present?
        session.confirmed_model = confirmed_model if confirmed_model.present?
        session.extracted_identifiers_list = (session.extracted_identifiers_list + Array(extracted_identifiers)).uniq
        session.user_clue_notes_list = (session.user_clue_notes_list + Array(user_clue_notes)).uniq
        session.needs_catalog_review = (
          resolution_status != "confirmed_candidate" ||
          !!was_edited ||
          session.gold_alignment_status != "GOLD ALIGNED"
        )
        session.resolved_at = Time.now.utc
        session.save!

        if defined?(ProductTelemetryEvent) && ProductTelemetryEvent.table_exists?
          ev = ProductTelemetryEvent.create!(
            event_name: "discovery.session_resolved",
            event_domain: "discovery",
            network_site_id: session.network_site_id,
            client_platform: client_platform.to_s,
            device_id: device_id.to_s,
            session_id: session.session_id,
            target_entity_type: monitored_device_id ? "MonitoredDevice" : "DiscoverySession",
            target_entity_id: (monitored_device_id || session.session_id).to_s,
            latency_ms: session.total_latency_ms,
            llm_turns: session.total_llm_turns,
            total_tokens: session.total_tokens,
            properties: {
              resolutionStatus: resolution_status,
              selectedCandidateRank: selected_candidate_rank,
              wasEdited: !!was_edited,
              initialMode: session.initial_mode,
              finalMode: session.final_mode,
              turnsCount: session.turns_count,
              inferredVendor: session.inferred_vendor,
              inferredModel: session.inferred_model,
              confirmedVendor: session.confirmed_vendor,
              confirmedModel: session.confirmed_model,
              goldAlignmentStatus: session.gold_alignment_status,
              needsCatalogReview: session.needs_catalog_review
            }
          )
          Telemetry::HostedAiLogger.log_product_event(ev.to_telemetry_hash)
        end

        session
      rescue StandardError => e
        Rails.logger.warn("[Discovery::HardwareVisionService] Resolution telemetry DB write skipped: #{e.message}")
        nil
      end

      def call_elastix_chat_completions(session_id:, turn_index:, previous_guess:, clues:, ephemeral_frames:)
        api_key = ENV["ELASTIX_API_KEY"].to_s.strip
        raise "ELASTIX_API_KEY not configured" if api_key.empty?

        model = ENV.fetch("ELASTIX_MODEL", "qwen3.8-27b")
        clue_context = clues[:flat_list].any? ? clues[:flat_list].map { |c| "- #{c}" }.join("\n") : "None provided yet."

        system_prompt = <<~SYS.strip
          /no_think
          You are a hardware device inventory discovery assistant for Tuesday.sh running on Elastix.ai.
          LATENCY CRITICAL: Keep internal thinking/reasoning under 25 words. Do NOT over-deliberate. Output the JSON object immediately with concise 1-sentence fields.
          SPATIAL SALIENCE, VISUAL POINTERS & MULTI-DEVICE RULES:
          - PRIMARY SUBJECT RULE (CENTER OF FRAME & ARROWS): Always prioritize the device at the CENTER/FOREGROUND of the photo or explicitly indicated by a visual pointer (red arrow, circle, bounding box, or finger). Candidate #1 (rank 0) MUST identify that primary central/pointed-to device—NEVER rank a background or edge device #1 just because its LEDs or brand logo are easier to recognize.
          - NO CROSS-CHASSIS FEATURE BLEEDING OR REFLECTION CONFUSION: Never merge ports, LEDs, or logos from an adjacent peripheral chassis (e.g. a NAS on the left edge) or a mirrored reflection on a glossy side panel onto the central device.
          - Set "multipleDevicesDetected": true whenever 2 or more distinct physical hardware chassis/units are visible in the photo. List the central/annotated device as Candidate #1 and any peripheral/adjacent device as Candidate #2/#3 with spatial tags in displayName (e.g. "[Center / Arrow] ...", "[Left Edge] ...").
          - Inspect rotated/vertical module stickers, FCC IDs, silkscreened board numbers, and SBC/PCB layouts carefully.
          Return ONLY a valid JSON object with the exact following keys:
          - "visualSummary": concise 1-sentence summary of all hardware devices and clues visible
          - "multipleDevicesDetected": boolean (true if 2+ distinct hardware chassis/enclosures are visible in the frame)
          - "nextNarrowingQuestion": concise question asking for Barcode, Serial Number, QR Code, Model, or MAC Address of the central target device
          - "recommendedClueTypes": array of strings from ["Model", "MAC Address", "Serial Number", "Barcode", "QR Code"]
          - "extractedIdentifiers": object with string or null fields {"barcode", "serialNumber", "qrCode", "modelNumber", "macAddress"}
          - "candidates": array of up to 3 objects (Candidate #1 MUST be the central/pointed-to device), each with exact keys:
            - "manufacturer": string
            - "modelNumber": string
            - "displayName": string
            - "deviceCategory": string
            - "confidencePercent": integer (1 to 99)
            - "reasoning": concise 1-sentence reason
            - "suggestedHostname": string
            - "suggestedOsDetails": plain string (e.g. "UniFi OS 4.0.20 (Debian 12 apt)")
            - "suggestedPackageManager": string from ["apt", "apk", "brew", "yum", "docker", "hacs", "firmware"]
        SYS

        user_prompt = <<~USR.strip
          <accumulated_clues>
          Turn #{turn_index}:
          #{clue_context}
          </accumulated_clues>
          Analyze the hardware photo(s) and clues and return the JSON object immediately. /no_think
        USR

        content_parts = [{ "type" => "text", "text" => user_prompt }]
        ephemeral_frames.each do |b64|
          next if b64.to_s.strip.empty?

          content_parts << {
            "type" => "image_url",
            "image_url" => { "url" => "data:image/jpeg;base64,#{b64}" }
          }
        end

        request_body = {
          "model" => model,
          "temperature" => 0.2,
          "max_tokens" => 850,
          "response_format" => { "type" => "json_object" },
          "metadata" => {
            "session_id" => session_id.presence || "tuesday-server-vision"
          },
          "messages" => [
            { "role" => "system", "content" => system_prompt },
            { "role" => "user", "content" => ephemeral_frames.any? ? content_parts : user_prompt }
          ]
        }

        uri = URI(ELASTIX_ENDPOINT)
        req = Net::HTTP::Post.new(uri)
        req["Authorization"] = "Bearer #{api_key}"
        req["Content-Type"] = "application/json"
        req["Accept"] = "application/json"
        req.body = JSON.generate(request_body)

        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 28) do |http|
          http.request(req)
        end

        unless res.is_a?(Net::HTTPSuccess)
          raise "Elastix HTTP #{res.code}: #{res.body.to_s[0, 200]}"
        end

        parsed = JSON.parse(res.body)
        raw_content = parsed.dig("choices", 0, "message", "content").to_s
        raise "Empty Elastix response content" if raw_content.strip.empty?

        usage_obj = parsed["usage"] || {}
        usage = {
          input_tokens: usage_obj["prompt_tokens"].to_i,
          output_tokens: usage_obj["completion_tokens"].to_i,
          cache_read_tokens: usage_obj.dig("prompt_tokens_details", "cached_tokens").to_i
        }

        {
          result: parse_turn_json(raw_content, clues),
          raw_text: raw_content,
          usage: usage,
          model: parsed["model"].presence || model
        }
      end

      def call_gemini_interactions(turn_index:, previous_guess:, clues:, ephemeral_frames:)
        api_key = ENV["GEMINI_API_KEY"].to_s.strip
        raise "GEMINI_API_KEY not configured" if api_key.empty?

        model = ENV.fetch("GEMINI_MODEL", "gemini-3.8-flash")
        clue_context = clues[:flat_list].any? ? clues[:flat_list].map { |c| "- #{c}" }.join("\n") : "None provided yet."

        prompt_text = <<~PROMPT.strip
          <instructions>
          You are a hardware device inventory discovery assistant for Tuesday.sh (a home lab, router, switch, NAS, SBC, Mini PC, and IoT package/firmware telemetry platform).
          Analyze the attached hardware device photo(s) along with any user-supplied identifiers (barcode, serial number, QR code, model number, or MAC address).
          1. PRIMARY SUBJECT & VISUAL POINTER RULE: Always identify the device that occupies the CENTER/FOREGROUND of the photo or is explicitly indicated by a user annotation (drawn red arrow, circle, box, or finger). Candidate #1 (rank 0) MUST be that central/annotated device—NEVER rank a peripheral/background device #1 just because its LEDs or branding are easier to recognize!
          2. ANTI-CONTAMINATION & REFLECTION RULE: Do NOT blend features (ports, LEDs, form factor) from an adjacent peripheral chassis (such as a cropped Synology NAS on the left edge) or a backwards mirrored reflection on a glossy side panel (such as a reflected logo from an adjacent drive enclosure) onto the central device. For example, a slim vertical box with Wi-Fi + POWER LEDs, front USB-A, USB-C, and a 3.5mm audio jack is a Mini PC / Thin Client / USB-C Dock, NOT a NAS sitting beside it.
          3. MULTI-DEVICE DETECTION: Set `multipleDevicesDetected` to `true` whenever 2 or more distinct physical hardware chassis/units are visible in the photo. Prefix each candidate's `displayName` with its spatial location (e.g., `[Center / Arrow] ...`, `[Left Edge] ...`).
          4. Extract any visible Barcode, Serial Number, QR Code payload, FCC ID, Model Number, or MAC Address from the photo(s) (including rotated/vertical daughterboard stickers and PCB silkscreen markings) or user clues.
          5. Rank up to 3 candidate hardware devices (fields: manufacturer, modelNumber, displayName, deviceCategory, confidencePercent 1-99, reasoning, suggestedHostname, suggestedOsDetails, suggestedPackageManager from [apt, apk, brew, yum, docker, hacs, firmware]).
          6. Formulate a concise `nextNarrowingQuestion` asking the user for the Barcode, Serial Number, Model, or MAC Address of the central target device.
          </instructions>
          <accumulated_clues>
          Turn #{turn_index}:
          #{clue_context}
          </accumulated_clues>
        PROMPT

        input_items = [{ "type" => "text", "text" => prompt_text }]
        ephemeral_frames.each do |b64|
          next if b64.to_s.strip.empty?

          input_items << {
            "type" => "image",
            "data" => b64,
            "mime_type" => "image/jpeg"
          }
        end

        request_body = {
          "model" => model,
          "input" => input_items,
          "generation_config" => {
            "thinking_level" => "low",
            "temperature" => 0.2
          },
          "response_format" => {
            "type" => "text",
            "mime_type" => "application/json",
            "schema" => gemini_turn_schema
          }
        }

        uri = URI(GEMINI_INTERACTIONS_ENDPOINT)
        req = Net::HTTP::Post.new(uri)
        req["x-goog-api-key"] = api_key
        req["Content-Type"] = "application/json"
        req["Accept"] = "application/json"
        req.body = JSON.generate(request_body)

        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 18) do |http|
          http.request(req)
        end

        unless res.is_a?(Net::HTTPSuccess)
          raise "Gemini HTTP #{res.code}: #{res.body.to_s[0, 200]}"
        end

        parsed = JSON.parse(res.body)
        text_output = parsed["output_text"].presence
        if text_output.nil?
          Array(parsed["outputs"]).reverse_each do |o|
            if o["text"].present?
              text_output = o["text"]
              break
            end
          end
        end
        if text_output.nil?
          Array(parsed["steps"]).reverse_each do |step|
            next unless step["type"] == "model_output"

            Array(step["content"]).each do |item|
              if item["text"].present?
                text_output = item["text"]
                break
              end
            end
            break if text_output.present?
          end
        end
        raise "Empty Gemini Interactions output" if text_output.to_s.strip.empty?

        usage_obj = parsed["usage"] || parsed["usageMetadata"] || {}
        usage = {
          input_tokens: (usage_obj["input_tokens"] || usage_obj["total_input_tokens"] || usage_obj["promptTokenCount"] || 680).to_i,
          output_tokens: (usage_obj["output_tokens"] || usage_obj["total_output_tokens"] || usage_obj["candidatesTokenCount"] || 190).to_i,
          cache_read_tokens: (usage_obj["cached_content_token_count"] || usage_obj["cachedContentTokenCount"] || 0).to_i
        }

        {
          result: parse_turn_json(text_output, clues),
          raw_text: text_output,
          usage: usage,
          model: model
        }
      end

      def gemini_turn_schema
        {
          "type" => "object",
          "properties" => {
            "visualSummary" => { "type" => "string" },
            "multipleDevicesDetected" => { "type" => "boolean" },
            "nextNarrowingQuestion" => { "type" => "string" },
            "recommendedClueTypes" => {
              "type" => "array",
              "items" => { "type" => "string" }
            },
            "extractedIdentifiers" => {
              "type" => "object",
              "properties" => {
                "barcode" => { "type" => "string" },
                "serialNumber" => { "type" => "string" },
                "qrCode" => { "type" => "string" },
                "modelNumber" => { "type" => "string" },
                "macAddress" => { "type" => "string" }
              }
            },
            "candidates" => {
              "type" => "array",
              "items" => {
                "type" => "object",
                "properties" => {
                  "manufacturer" => { "type" => "string" },
                  "modelNumber" => { "type" => "string" },
                  "displayName" => { "type" => "string" },
                  "deviceCategory" => { "type" => "string" },
                  "confidencePercent" => { "type" => "integer" },
                  "reasoning" => { "type" => "string" },
                  "suggestedHostname" => { "type" => "string" },
                  "suggestedOsDetails" => { "type" => "string" },
                  "suggestedPackageManager" => { "type" => "string" }
                },
                "required" => %w[manufacturer modelNumber displayName deviceCategory confidencePercent reasoning suggestedHostname suggestedOsDetails suggestedPackageManager]
              }
            }
          },
          "required" => %w[visualSummary multipleDevicesDetected nextNarrowingQuestion recommendedClueTypes extractedIdentifiers candidates]
        }
      end

      MULTI_DEVICE_WARNING_MESSAGE = "Multiple devices detected in this photo. Confidence can be lower when neighboring chassis appear in frame — for best results, snap a new photo framed around a single device."

      def parse_turn_json(raw_text, clues)
        cleaned = raw_text.to_s.strip
                          .sub(/\A```json\s*/i, "")
                          .sub(/\A```\s*/i, "")
                          .sub(/\s*```\z/, "")
                          .strip
        if !cleaned.start_with?("{") && cleaned.include?("{") && cleaned.include?("}")
          cleaned = cleaned[cleaned.index("{")..cleaned.rindex("}")]
        end

        json = JSON.parse(cleaned)
        ext = json["extractedIdentifiers"].is_a?(Hash) ? json["extractedIdentifiers"] : {}
        merged_obj = {
          "barcode" => ext["barcode"].presence || clues[:object]["barcode"],
          "serialNumber" => ext["serialNumber"].presence || clues[:object]["serialNumber"],
          "qrCode" => ext["qrCode"].presence || clues[:object]["qrCode"],
          "modelNumber" => ext["modelNumber"].presence || clues[:object]["modelNumber"],
          "macAddress" => ext["macAddress"].presence || clues[:object]["macAddress"]
        }

        candidates = Array(json["candidates"]).map do |c|
          os_raw = c["suggestedOsDetails"]
          os_str = os_raw.is_a?(Hash) ? "#{os_raw['osName']} #{os_raw['osVersion']}".strip : os_raw.to_s
          {
            "manufacturer" => c["manufacturer"].presence || "Unknown Vendor",
            "modelNumber" => c["modelNumber"].presence || "Unknown Model",
            "displayName" => c["displayName"].presence || "#{c['manufacturer']} #{c['modelNumber']}".strip,
            "deviceCategory" => c["deviceCategory"].presence || "Network Hardware",
            "confidencePercent" => (c["confidencePercent"] || 70).to_i.clamp(1, 99),
            "reasoning" => c["reasoning"].presence || "Identified from visual chassis and clues.",
            "suggestedHostname" => c["suggestedHostname"].presence || "device.local",
            "suggestedOsDetails" => os_str.presence || "Linux / Embedded Firmware",
            "suggestedPackageManager" => c["suggestedPackageManager"].presence || "firmware"
          }
        end

        vis_summary = json["visualSummary"].presence || "Analyzed device hardware."
        multi_detected = if json.key?("multipleDevicesDetected")
                           !!json["multipleDevicesDetected"]
                         else
                           vis_summary.match?(/\b(beside|next to|alongside|second |multiple |left unit|right unit|two .*chassis|two .*devices)\b/i)
                         end

        top = candidates.first || {}
        {
          "visualSummary" => vis_summary,
          "multipleDevicesDetected" => multi_detected,
          "multiDeviceWarning" => multi_detected ? MULTI_DEVICE_WARNING_MESSAGE : nil,
          "nextNarrowingQuestion" => json["nextNarrowingQuestion"].presence || "Can you check for a Barcode, Serial Number, Model, or MAC Address on the label?",
          "recommendedClueTypes" => Array(json["recommendedClueTypes"]).presence || DEFAULT_CLUE_TYPES,
          "extractedIdentifiersObject" => merged_obj,
          "candidates" => candidates,
          "vendor" => top["manufacturer"] || json["vendor"] || "Unknown Vendor",
          "model" => top["modelNumber"] || json["model"] || "Unidentified Hardware",
          "confidence" => ((top["confidencePercent"] || 70).to_f / 100.0).round(2),
          "reasoning" => top["reasoning"] || vis_summary,
          "nextPromptForUser" => json["nextNarrowingQuestion"]
        }
      end

      def heuristic_infer(turn_index:, previous_guess:, clues:)
        joined = clues[:flat_list].join(" ").downcase
        has_clue = clues[:flat_list].any? || turn_index.to_i > 1
        top_conf = has_clue ? 94 : 68
        model_num = clues[:object]["modelNumber"] || (has_clue ? "UCG-Ultra" : "UCG-Ultra / UXG-Max")

        {
          "visualSummary" => has_clue ? "Verified compact polycarbonate desktop security gateway with front LCM status display and multi-gigabit RJ45 ports." : "Identified a compact white desktop router / network gateway chassis.",
          "nextNarrowingQuestion" => has_clue ? "Identifier verified! Candidate narrowed to Ubiquiti UniFi Cloud Gateway Ultra (UCG-Ultra). Confirm match below." : "To narrow between UniFi Cloud Gateway Ultra (UCG-Ultra) and Gateway Max (UXG-Max), is there a Barcode, Serial Number, or Model on the bottom label?",
          "recommendedClueTypes" => DEFAULT_CLUE_TYPES,
          "extractedIdentifiersObject" => clues[:object],
          "candidates" => [
            {
              "manufacturer" => "Ubiquiti Inc.",
              "modelNumber" => model_num,
              "displayName" => "UniFi Cloud Gateway Ultra (#{model_num})",
              "deviceCategory" => "Router / Security Gateway",
              "confidencePercent" => top_conf,
              "reasoning" => "Matches Ubiquiti desktop gateway form factor running UniFi OS.",
              "suggestedHostname" => "unifi-ucg-ultra",
              "suggestedOsDetails" => "UniFi OS 4.0.20 (Debian 12 apt)",
              "suggestedPackageManager" => "apt"
            },
            {
              "manufacturer" => "GL.iNet",
              "modelNumber" => "GL-MT3000",
              "displayName" => "GL.iNet Beryl AX (GL-MT3000)",
              "deviceCategory" => "OpenWrt Travel / Edge Router",
              "confidencePercent" => has_clue ? 18 : 34,
              "reasoning" => "Alternative compact white rounded-rectangle Wi-Fi 6 router chassis.",
              "suggestedHostname" => "gl-mt3000.local",
              "suggestedOsDetails" => "OpenWrt 23.05 (opkg firmware)",
              "suggestedPackageManager" => "firmware"
            }
          ],
          "vendor" => "Ubiquiti Inc.",
          "model" => model_num,
          "confidence" => (top_conf / 100.0).round(2),
          "reasoning" => "Matches Ubiquiti desktop gateway form factor running UniFi OS."
        }
      end

      def normalize_model_slug(raw_model)
        raw_model.to_s
                 .downcase
                 .gsub("+", "-plus")
                 .gsub(/[^a-z0-9]+/, "-")
                 .gsub(/\A-+|-+\z/, "")
      end

      def extract_candidate_model_slugs(raw_model)
        raw = raw_model.to_s.strip
        return [] if raw.empty?

        parts = [raw] + raw.split(/\s*(?:\/|,|\bor\b)\s*/i)
        # Also extract embedded chip/board tokens like ESP8266, ESP8266MOD, ESP32, RPi-4B, etc.
        raw.scan(/\b(esp8266(?:mod)?|esp32(?:-[a-z0-9]+)?|esp-12[ef]|nodemcu|d1-mini)\b/i).flatten.each do |tok|
          parts << tok
        end
        slugs = []
        parts.each do |part|
          cleaned_part = part.sub(/\b(series|family|line|models?)\b/i, "").strip
          next if cleaned_part.empty?

          norm = normalize_model_slug(cleaned_part)
          plain = cleaned_part.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
          [norm, plain].each do |s|
            next if s.length < 2
            next if %w[device unknown unknown-model unidentified-hardware generic mini-pc router switch nas modem].include?(s)

            slugs << s
            base = s.sub(/-(100nas|200nas|us|eu|uk|au|ca|v\d+)\z/, "")
            slugs << base if base.length >= 2
          end
        end
        slugs.uniq
      end

      def infer_candidate_purl(vendor:, model:, os_details: "")
        primary_vendor = vendor.to_s.split(/\s*\/\s*/).first.to_s.strip
        primary_model = model.to_s.split(/\s*\/\s*/).first.to_s.strip
        v_down = primary_vendor.downcase
        m_down = primary_model.downcase
        os_down = os_details.to_s.downcase
        m_slug = normalize_model_slug(primary_model).presence || "device"
        v_slug = v_down.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "").presence || "generic"
        has_specific_model = !%w[device unknown unknown-model unidentified-hardware].include?(m_slug)

        if v_down.include?("ubiquiti") || v_down.include?("unifi") || m_down.match?(/\b(udm|ucg|uxg|usw|u6|u7)\b/)
          if has_specific_model
            "pkg:generic/ui/#{m_slug}"
          else
            "pkg:generic/ui/unifi-os"
          end
        elsif v_down.include?("netgear") || m_down.include?("r7000") || m_down.include?("nighthawk")
          "pkg:generic/netgear/#{m_slug}"
        elsif v_down.include?("synology") || (v_down.empty? && os_down.include?("dsm"))
          has_specific_model ? "pkg:generic/synology/#{m_slug}" : "pkg:generic/synology/dsm"
        elsif v_down.include?("cisco")
          has_specific_model ? "pkg:generic/cisco/#{m_slug}" : "pkg:generic/cisco/ios-xe"
        elsif v_down.include?("ecobee")
          "pkg:generic/ecobee/#{m_slug}"
        elsif v_down.include?("owlet")
          "pkg:generic/owlet/#{m_slug}"
        elsif v_down.include?("lg") || (v_down.empty? && os_down.include?("webos"))
          "pkg:generic/lg/webos"
        elsif v_down.include?("esphome") || os_down.include?("esphome")
          "pkg:generic/esphome/firmware"
        elsif v_down.include?("limetech") || v_down.include?("unraid") || os_down.include?("unraid")
          "pkg:generic/limetech/unraid"
        elsif v_down.include?("proxmox") || os_down.include?("proxmox")
          "pkg:deb/debian/proxmox-ve"
        elsif v_down.include?("apple")
          has_specific_model && !m_slug.include?("macos") ? "pkg:generic/apple/#{m_slug}" : "pkg:generic/apple/macos"
        elsif v_down.include?("nintendo")
          "pkg:generic/nintendo/horizon-os"
        else
          "pkg:generic/#{v_slug}/#{m_slug}"
        end
      end

      def load_gold_feeds_raw
        lake_dir = Bulletins::GoldSnapshotLoader.resolve_lake_dir
        path = File.join(lake_dir, "canonical_feeds.json")
        return [] unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue StandardError
        []
      end

      def load_gold_releases_raw
        lake_dir = Bulletins::GoldSnapshotLoader.resolve_lake_dir
        path = File.join(lake_dir, "catalog_releases.json")
        return [] unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue StandardError
        []
      end

      def audit_candidates_against_gold_datalake(candidates, trace: nil)
        feeds = load_gold_feeds_raw
        releases = load_gold_releases_raw
        idx_map = confirmed_catalog_index
        confirmed_entries = idx_map[:entries]

        Array(candidates).map.with_index(1) do |cand, idx|
          vendor = cand["manufacturer"].to_s
          model = cand["modelNumber"].to_s
          os_details = cand["suggestedOsDetails"].to_s
          inferred_purl = infer_candidate_purl(vendor: vendor, model: model, os_details: os_details)
          model_slug = model.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
          vendor_slug = vendor.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")

          matched_feed = feeds.find do |f|
            Array(f["purl_prefixes"]).any? do |prefix|
              p_str = prefix.to_s
              inferred_purl.start_with?(p_str) || p_str.start_with?(inferred_purl.split("/")[0..2].join("/"))
            end
          end

          exact_release = releases.find do |r|
            inferred_purl == r["purl_base"].to_s || inferred_purl.start_with?("#{r['purl_base']}/")
          end

          feed_release = exact_release || releases.find do |r|
            matched_feed && r["canonical_feed_slug"] == matched_feed["slug"]
          end

          in_builtin = BUILT_IN_CATALOG_SIGNATURES.any? do |sig|
            "#{vendor} #{model} #{cand['displayName']}".match?(sig[:pattern])
          end

          candidate_slugs = extract_candidate_model_slugs(model)
          matched_confirmed = idx_map[:by_purl][inferred_purl.downcase]
          if matched_confirmed.nil?
            candidate_slugs.each do |c_slug|
              matched_confirmed = idx_map[:by_purl]["pkg:generic/#{vendor_slug}/#{c_slug}"] ||
                                  (c_slug.length >= 3 && idx_map[:by_model_slug][c_slug])
              break if matched_confirmed
            end
          end
          in_confirmed = !matched_confirmed.nil?
          if matched_confirmed && matched_confirmed["canonical_purl"].present? && (matched_feed.nil? || model.include?("/"))
            inferred_purl = matched_confirmed["canonical_purl"]
            matched_feed ||= feeds.find do |f|
              Array(f["purl_prefixes"]).any? do |prefix|
                p_str = prefix.to_s
                inferred_purl.start_with?(p_str) || p_str.start_with?(inferred_purl.split("/")[0..2].join("/"))
              end
            end
          end

          exact_model_aligned = in_builtin || in_confirmed || !exact_release.nil?
          vendor_feed_only = !exact_model_aligned && !matched_feed.nil?
          aligned = exact_model_aligned

          matched_prefix = if matched_feed
                             Array(matched_feed["purl_prefixes"]).find do |p|
                               inferred_purl.start_with?(p.to_s) || p.to_s.start_with?(inferred_purl.split("/")[0..2].join("/"))
                             end
                           end

          trace&.call(
            "PURL_RESOLVE",
            "Candidate ##{idx}: \"#{vendor}\" + \"#{model}\" (OS: \"#{os_details}\") -> #{inferred_purl} " \
            "[builtIn=#{in_builtin}, confirmed=#{in_confirmed}, exactRelease=#{!exact_release.nil?}, vendorFeed=#{matched_feed ? matched_feed['slug'] : 'NONE'}]"
          )

          status_label = if aligned
                           "GOLD ALIGNED"
                         elsif vendor_feed_only
                           "UNALIGNED MODEL (VENDOR FEED ONLY)"
                         else
                           "UNALIGNED RAW MATCH"
                         end

          note_parts = []
          note_parts << "Built-in Catalog Signature" if in_builtin
          if matched_confirmed
            cat_c = matched_confirmed["category_code"]
            upc_c = matched_confirmed["upc_gtin"]
            fcc_c = matched_confirmed["fcc_id"]
            note_parts << "Gold Catalog SKU (#{cat_c || 'Verified'}#{upc_c ? " • UPC #{upc_c}" : ''}#{fcc_c ? " • FCC #{fcc_c}" : ''})"
          end
          note_parts << "Exact Release PURL (#{exact_release['purl_base']})" if exact_release
          note_parts << "Feed: #{matched_feed['slug']} (#{matched_prefix})" if matched_feed
          note_parts << "Gold Release: v#{feed_release['version']}" if feed_release

          diagnostic_note = if aligned
                              "Exact model in Gold Catalog [#{note_parts.join(' • ')}]"
                            elsif vendor_feed_only
                              "Model '#{model}' (#{inferred_purl}) is NOT in Gold Hardware Catalog; only vendor prefix #{matched_prefix} matched feed #{matched_feed['slug']}"
                            else
                              "Raw LLM candidate '#{vendor} #{model}' (#{inferred_purl}) has no matching model or vendor PURL prefix in Gold Datalake"
                            end

          alignment = {
            "aligned" => aligned,
            "vendorFeedOnly" => vendor_feed_only,
            "matchedFeedSlug" => matched_feed && matched_feed["slug"],
            "matchedFeedName" => matched_feed && matched_feed["pro_name"],
            "matchedPurlPrefix" => matched_prefix,
            "inferredPurl" => inferred_purl,
            "latestGoldRelease" => feed_release && feed_release["version"],
            "inBuiltInCatalog" => in_builtin,
            "inConfirmedCatalog" => in_confirmed,
            "categoryCode" => matched_confirmed && matched_confirmed["category_code"],
            "upcGtin" => matched_confirmed && matched_confirmed["upc_gtin"],
            "fccId" => matched_confirmed && matched_confirmed["fcc_id"],
            "fccGrantee" => matched_confirmed && matched_confirmed["fcc_grantee"],
            "statusLabel" => status_label,
            "diagnosticNote" => diagnostic_note
          }

          trace&.call(
            "GOLD_AUDIT",
            "Candidate ##{idx}: #{vendor} #{model} (#{cand['confidencePercent']}%) -> #{alignment['statusLabel']} | #{diagnostic_note}"
          )

          cand.merge("goldAlignment" => alignment)
        end
      end

      def format_debug_log_text(
        session_id:,
        turn_index:,
        client_platform:,
        provider_used:,
        model_used:,
        latency_ms:,
        cost_usd:,
        usage:,
        visual_summary:,
        extracted_identifiers:,
        candidates:,
        raw_llm_response:,
        debug_trace:
      )
        lines = []
        lines << "=== TUESDAY VISION DEBUG LOG [#{Time.now.utc.strftime('%H:%M:%S.%L UTC')}] ==="
        lines << "Session: #{session_id} (Turn ##{turn_index} • #{client_platform})"
        lines << "Provider: #{provider_used} • Model: #{model_used} • Latency: #{latency_ms}ms"
        lines << "Tokens: in=#{usage[:input_tokens]} out=#{usage[:output_tokens]} cached=#{usage[:cache_read_tokens]}"
        lines << "Visual Summary: #{visual_summary}"
        lines << "Extracted Identifiers: #{JSON.generate(extracted_identifiers)}"
        lines << ""
        lines << "--- PIPELINE TRACE ---"
        Array(debug_trace).each { |t| lines << t }
        lines << ""
        lines << "--- CANDIDATES & GOLD DATALAKE ALIGNMENT (#{Array(candidates).size}) ---"
        Array(candidates).each_with_index do |c, idx|
          ga = c["goldAlignment"] || {}
          badge = if ga["aligned"]
                    "[✓ GOLD ALIGNED]"
                  elsif ga["vendorFeedOnly"]
                    "[⚠ VENDOR FEED ONLY]"
                  else
                    "[⚠ UNALIGNED RAW]"
                  end
          lines << "  #{idx + 1}. #{badge} #{c['manufacturer']} #{c['modelNumber']} (#{c['confidencePercent']}%)"
          lines << "     Display: #{c['displayName']} | Category: #{c['deviceCategory']} | Pkg: #{c['suggestedPackageManager']}"
          lines << "     PURL: #{ga['inferredPurl']} | Feed: #{ga['matchedFeedSlug'] || 'NONE'} | Gold Rel: #{ga['latestGoldRelease'] || 'NONE'}"
          lines << "     Reason: #{c['reasoning']}"
          lines << "     Audit: #{ga['diagnosticNote']}"
        end
        if raw_llm_response && !raw_llm_response.to_s.strip.empty?
          lines << ""
          lines << "--- RAW UPSTREAM LLM JSON ---"
          lines << raw_llm_response.to_s.strip
        end
        lines.join("\n")
      end

      def confirmed_catalog_path
        return RUNTIME_CONFIRMED_CATALOG_FILE if File.exist?(RUNTIME_CONFIRMED_CATALOG_FILE)
        return CONFIRMED_CATALOG_FILE if File.exist?(CONFIRMED_CATALOG_FILE)
        return BUNDLED_CONFIRMED_CATALOG_FILE if File.exist?(BUNDLED_CONFIRMED_CATALOG_FILE)

        RUNTIME_CONFIRMED_CATALOG_FILE
      end

      def load_confirmed_catalog
        path = confirmed_catalog_path
        return [] unless File.exist?(path)

        mtime = File.mtime(path).to_f
        if @cached_catalog_path == path && @cached_catalog_mtime == mtime && @cached_catalog_entries
          return @cached_catalog_entries
        end

        parsed = JSON.parse(File.read(path))
        entries = parsed.is_a?(Hash) ? Array(parsed["identifiers"]) : Array(parsed)
        @cached_fcc_grantees = parsed.is_a?(Hash) ? (parsed["fcc_grantees"] || {}) : {}
        @cached_catalog_path = path
        @cached_catalog_mtime = mtime
        @cached_catalog_entries = entries
        @cached_catalog_index = nil
        entries
      rescue StandardError
        []
      end

      def confirmed_catalog_index
        entries = load_confirmed_catalog
        return @cached_catalog_index if @cached_catalog_index

        by_upc = {}
        by_fcc_id = {}
        by_identifier = {}
        by_purl = {}
        by_model_slug = {}

        entries.each do |e|
          upc = e["upc_gtin"].to_s.gsub(/[^0-9]/, "")
          by_upc[upc] = e if upc.length >= 8

          fcc = e["fcc_id"].to_s.upcase.gsub(/[^A-Z0-9]/, "")
          by_fcc_id[fcc] = e if fcc.length >= 5

          ident = e["identifier"].to_s.strip.downcase
          by_identifier[ident] = e if ident.length >= 4

          purl = e["canonical_purl"].to_s.strip.downcase
          by_purl[purl] = e unless purl.empty?

          m_slug = normalize_model_slug(e["model"])
          by_model_slug[m_slug] ||= e if m_slug.length >= 3

          plain_slug = e["model"].to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
          by_model_slug[plain_slug] ||= e if plain_slug.length >= 3

          no_plus_slug = m_slug.sub(/-plus\z/, "")
          by_model_slug[no_plus_slug] ||= e if no_plus_slug.length >= 3
        end

        @cached_catalog_index = {
          entries: entries,
          fcc_grantees: @cached_fcc_grantees || {},
          by_upc: by_upc,
          by_fcc_id: by_fcc_id,
          by_identifier: by_identifier,
          by_purl: by_purl,
          by_model_slug: by_model_slug
        }
      end

      def promote_confirmed_identifiers(identifiers:, vendor:, model:, lifecycle_tier:, trust_zone:)
        target_path = if !Rails.env.test? && File.directory?(File.dirname(CONFIRMED_CATALOG_FILE))
                        CONFIRMED_CATALOG_FILE
                      else
                        RUNTIME_CONFIRMED_CATALOG_FILE
                      end
        FileUtils.mkdir_p(File.dirname(target_path))
        entries = load_confirmed_catalog.dup
        identifiers.each do |raw_id|
          cleaned = raw_id.to_s.strip
          next if cleaned.length < 4

          existing = entries.find { |e| e["identifier"].to_s.casecmp?(cleaned) }
          if existing
            existing["vendor"] = vendor
            existing["model"] = model
            existing["lifecycle_tier"] = lifecycle_tier
            existing["trust_zone"] = trust_zone
            existing["updated_at"] = Time.now.utc.iso8601
          else
            v_slug = vendor.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
            m_slug = model.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
            entries << {
              "identifier" => cleaned,
              "vendor" => vendor,
              "brand" => vendor,
              "model" => model,
              "canonical_purl" => "pkg:generic/#{v_slug}/#{m_slug}",
              "category_code" => "C8",
              "upc_gtin" => cleaned.match?(/\A\d{8,14}\z/) ? cleaned : nil,
              "match_tier" => "USER_CONFIRMED",
              "lifecycle_tier" => lifecycle_tier,
              "trust_zone" => trust_zone,
              "updated_at" => Time.now.utc.iso8601
            }
          end
        end
        payload = {
          "updated_at" => Time.now.utc.iso8601,
          "total_matchable_products" => entries.size,
          "fcc_grantees" => @cached_fcc_grantees || {},
          "identifiers" => entries
        }
        File.write(target_path, JSON.pretty_generate(payload))
        @cached_catalog_mtime = nil
        @cached_catalog_index = nil
      rescue StandardError => e
        Rails.logger.warn("[Discovery::HardwareVisionService] Confirmed catalog update skipped: #{e.message}")
      end
    end
  end
end
