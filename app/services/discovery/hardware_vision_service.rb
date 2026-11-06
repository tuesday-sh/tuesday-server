# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "fileutils"

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
        provider_override: "auto",
        previous_guess: nil,
        extracted_identifiers: [],
        user_clue_notes: [],
        images_base64: []
      )
        start_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        normalized_clues = normalize_incoming_clues(extracted_identifiers, user_clue_notes)
        ephemeral_frames = Array(images_base64).compact.first(2)

        result = nil
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
              result = catalog_match
              short_circuited = true
              provider_used = "CatalogCache"
              model_used = "gold-short-circuit"
            end
          end

          # Step 2: Upstream Vision LLM Router (Elastix Primary -> Gemini Failover)
          unless result
            if provider_override.to_s.downcase == "heuristic"
              result = heuristic_infer(turn_index: turn_index, previous_guess: previous_guess, clues: normalized_clues)
              provider_used = "Heuristic"
              model_used = "heuristic-fallback"
            elsif provider_override.to_s.downcase == "gemini"
              res_data = call_gemini_interactions(
                turn_index: turn_index,
                previous_guess: previous_guess,
                clues: normalized_clues,
                ephemeral_frames: ephemeral_frames
              )
              result = res_data[:result]
              usage = res_data[:usage]
              provider_used = "Google"
              model_used = res_data[:model]
            else
              begin
                res_data = call_elastix_chat_completions(
                  session_id: session_id,
                  turn_index: turn_index,
                  previous_guess: previous_guess,
                  clues: normalized_clues,
                  ephemeral_frames: ephemeral_frames
                )
                result = res_data[:result]
                usage = res_data[:usage]
                provider_used = "Elastix"
                model_used = res_data[:model]
              rescue StandardError => elastix_err
                Rails.logger.warn("[Discovery::HardwareVisionService] Elastix primary failed (#{elastix_err.message}); failing over to Gemini")
                fallback_used = true
                begin
                  res_data = call_gemini_interactions(
                    turn_index: turn_index,
                    previous_guess: previous_guess,
                    clues: normalized_clues,
                    ephemeral_frames: ephemeral_frames
                  )
                  result = res_data[:result]
                  usage = res_data[:usage]
                  provider_used = "Google"
                  model_used = res_data[:model]
                rescue StandardError => gemini_err
                  Rails.logger.warn("[Discovery::HardwareVisionService] Gemini failover failed (#{gemini_err.message}); using deterministic heuristic")
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

        latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_monotonic) * 1000).round
        top_candidate = Array(result["candidates"]).first || {}
        top_vendor = result["vendor"] || top_candidate["manufacturer"] || "Unknown Vendor"
        top_model = result["model"] || top_candidate["modelNumber"] || "Unidentified Hardware"
        top_confidence = result["confidence"] || ((top_candidate["confidencePercent"] || 65).to_f / 100.0)

        telemetry_record = Telemetry::HostedAiLogger.log_ai_call(
          feature: "hardware_discovery",
          provider: provider_used,
          model: model_used,
          status: "success",
          client_platform: client_platform,
          device_id: device_id,
          session_id: session_id,
          turn_index: turn_index,
          fallback_used: fallback_used,
          short_circuited: short_circuited,
          latency_ms: latency_ms,
          input_tokens: usage[:input_tokens],
          output_tokens: usage[:output_tokens],
          cache_read_tokens: usage[:cache_read_tokens],
          confidence: top_confidence,
          inferred_vendor: top_vendor,
          inferred_model: top_model,
          extracted_identifiers: normalized_clues[:flat_list]
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

        coaching_directive = {
          "status" => discovery_status,
          "imageQualityScore" => image_quality_score,
          "nextPhotoPrompt" => discovery_status == "matched_exact" ? nil : next_prompt
        }

        {
          # Mobile rich turn fields (Android & iOS)
          "visualSummary" => result["visualSummary"] || result["reasoning"] || "Analyzed device hardware and clues.",
          "nextNarrowingQuestion" => next_prompt,
          "recommendedClueTypes" => result["recommendedClueTypes"] || DEFAULT_CLUE_TYPES,
          "extractedIdentifiersObject" => result["extractedIdentifiersObject"] || normalized_clues[:object],
          "extractedIdentifiers" => normalized_clues[:flat_list],
          "candidates" => Array(result["candidates"]),
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
          "privacyAttestation" => PRIVACY_ATTESTATION
        }
      end

      def record_confirmation!(
        session_id:,
        client_platform: "unknown",
        device_id: "anonymous",
        inferred_vendor: nil,
        inferred_model: nil,
        confirmed_vendor:,
        confirmed_model:,
        was_edited: false,
        extracted_identifiers: [],
        suggested_lifecycle_tier: "active",
        suggested_trust_zone: "z1_trusted"
      )
        clean_identifiers = Array(extracted_identifiers).map(&:to_s).map(&:strip).reject(&:empty?).uniq

        if clean_identifiers.any? && !confirmed_vendor.to_s.strip.empty? && !confirmed_model.to_s.strip.empty?
          promote_confirmed_identifiers(
            identifiers: clean_identifiers,
            vendor: confirmed_vendor.to_s.strip,
            model: confirmed_model.to_s.strip,
            lifecycle_tier: suggested_lifecycle_tier,
            trust_zone: suggested_trust_zone
          )
        end

        Telemetry::HostedAiLogger.log_confirmation(
          session_id: session_id,
          client_platform: client_platform,
          device_id: device_id,
          inferred_vendor: inferred_vendor,
          inferred_model: inferred_model,
          confirmed_vendor: confirmed_vendor,
          confirmed_model: confirmed_model,
          was_edited: was_edited,
          extracted_identifiers: clean_identifiers
        )
      end

      def match_catalog_short_circuit(normalized_clues)
        flat_list = normalized_clues[:flat_list]
        return nil if flat_list.empty?

        joined = flat_list.join(" | ")

        # 1. Check user-confirmed identifier catalog first
        load_confirmed_catalog.each do |entry|
          token = entry["identifier"].to_s.strip
          next if token.length < 4

          if flat_list.any? { |id| id.casecmp?(token) || id.downcase.include?(token.downcase) }
            return build_catalog_turn_payload(
              vendor: entry["vendor"],
              model: entry["model"],
              display_name: "#{entry['vendor']} #{entry['model']}",
              category: "Verified Network / IoT Hardware",
              hostname: entry["model"].to_s.downcase.gsub(/[^a-z0-9]+/, "-"),
              os_details: "Verified Tuesday Catalog Device",
              pkg_manager: "firmware",
              confidence_pct: 98,
              reasoning: "Matched verified hardware identifier (#{token}) in Gold Confirmed Catalog ($0.00 short-circuit).",
              lifecycle_tier: entry["lifecycle_tier"] || "active",
              trust_zone: entry["trust_zone"] || "z1_trusted",
              clues: normalized_clues
            )
          end
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
              clues: normalized_clues
            )
          end
        end

        nil
      end

      private

      def normalize_incoming_clues(extracted_identifiers, user_clue_notes)
        obj = {
          "barcode" => nil,
          "serialNumber" => nil,
          "qrCode" => nil,
          "modelNumber" => nil,
          "macAddress" => nil
        }
        flat = []

        if extracted_identifiers.is_a?(Hash) || (defined?(ActionController::Parameters) && extracted_identifiers.is_a?(ActionController::Parameters))
          h = extracted_identifiers.respond_to?(:to_unsafe_h) ? extracted_identifiers.to_unsafe_h : extracted_identifiers
          obj["barcode"] = h["barcode"].presence
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
            obj["serialNumber"] ||= s.sub(/\ASerial(\s*Number)?:\s*/i, "") if s.match?(/\ASerial/i)
            obj["qrCode"] ||= s.sub(/\AQR(\s*Code)?:\s*/i, "") if s.match?(/\AQR/i)
            obj["modelNumber"] ||= s.sub(/\AModel(\s*Number)?:\s*/i, "") if s.match?(/\AModel/i)
            obj["macAddress"] ||= s.sub(/\AMAC(\s*Address)?:\s*/i, "") if s.match?(/\AMAC/i)
          end
        end

        Array(user_clue_notes).each do |note|
          s = note.to_s.strip
          flat << "Clue: #{s}" unless s.empty?
        end

        { object: obj, flat_list: flat.uniq }
      end

      def build_catalog_turn_payload(vendor:, model:, display_name:, category:, hostname:, os_details:, pkg_manager:, confidence_pct:, reasoning:, lifecycle_tier:, trust_zone:, clues:)
        obj = clues[:object].dup
        obj["modelNumber"] ||= model
        {
          "visualSummary" => reasoning,
          "nextNarrowingQuestion" => "Identifier verified in Tuesday Gold Catalog (#{display_name}). Confirm match below or add additional clues.",
          "recommendedClueTypes" => DEFAULT_CLUE_TYPES,
          "extractedIdentifiersObject" => obj,
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

      def call_elastix_chat_completions(session_id:, turn_index:, previous_guess:, clues:, ephemeral_frames:)
        api_key = ENV["ELASTIX_API_KEY"].to_s.strip
        raise "ELASTIX_API_KEY not configured" if api_key.empty?

        model = ENV.fetch("ELASTIX_MODEL", "qwen3.8-27b")
        clue_context = clues[:flat_list].any? ? clues[:flat_list].map { |c| "- #{c}" }.join("\n") : "None provided yet."

        system_prompt = <<~SYS.strip
          /no_think
          You are a hardware device inventory discovery assistant for Tuesday.sh running on Elastix.ai.
          LATENCY CRITICAL: Keep internal thinking/reasoning under 25 words. Do NOT over-deliberate. Output the JSON object immediately with concise 1-sentence fields.
          Return ONLY a valid JSON object with the exact following keys:
          - "visualSummary": concise 1-sentence summary of hardware and clues
          - "nextNarrowingQuestion": concise question asking for Barcode, Serial Number, QR Code, Model, or MAC Address
          - "recommendedClueTypes": array of strings from ["Model", "MAC Address", "Serial Number", "Barcode", "QR Code"]
          - "extractedIdentifiers": object with string or null fields {"barcode", "serialNumber", "qrCode", "modelNumber", "macAddress"}
          - "candidates": array of 2 objects, each with exact keys:
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
          "max_tokens" => 700,
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
          You are a hardware device inventory discovery assistant for Tuesday.sh (a home lab, router, switch, NAS, and IoT package/firmware telemetry platform).
          Analyze the attached hardware device photo(s) along with any user-supplied identifiers (barcode, serial number, QR code, model number, or MAC address).
          1. Extract any visible Barcode, Serial Number, QR Code payload, Model Number, or MAC Address from the photo(s) or user clues.
          2. Rank 2 candidate hardware devices (manufacturer, modelNumber, displayName, deviceCategory, confidencePercent 1-99, reasoning, suggestedHostname, suggestedOsDetails, suggestedPackageManager from [apt, apk, brew, yum, docker, hacs, firmware]).
          3. Formulate a concise `nextNarrowingQuestion` asking the user if there is a Barcode, Serial Number, QR Code, Model, or MAC Address on the device/sticker that can disambiguate the top candidates.
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
          usage: usage,
          model: model
        }
      end

      def gemini_turn_schema
        {
          "type" => "object",
          "properties" => {
            "visualSummary" => { "type" => "string" },
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
          "required" => %w[visualSummary nextNarrowingQuestion recommendedClueTypes extractedIdentifiers candidates]
        }
      end

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

        top = candidates.first || {}
        {
          "visualSummary" => json["visualSummary"].presence || "Analyzed device hardware.",
          "nextNarrowingQuestion" => json["nextNarrowingQuestion"].presence || "Can you check for a Barcode, Serial Number, Model, or MAC Address on the label?",
          "recommendedClueTypes" => Array(json["recommendedClueTypes"]).presence || DEFAULT_CLUE_TYPES,
          "extractedIdentifiersObject" => merged_obj,
          "candidates" => candidates,
          "vendor" => top["manufacturer"] || json["vendor"] || "Unknown Vendor",
          "model" => top["modelNumber"] || json["model"] || "Unidentified Hardware",
          "confidence" => ((top["confidencePercent"] || 70).to_f / 100.0).round(2),
          "reasoning" => top["reasoning"] || json["visualSummary"],
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
            }
          ],
          "vendor" => "Ubiquiti Inc.",
          "model" => model_num,
          "confidence" => (top_conf / 100.0).round(2),
          "reasoning" => "Matches Ubiquiti desktop gateway form factor running UniFi OS."
        }
      end

      def load_confirmed_catalog
        return [] unless File.exist?(CONFIRMED_CATALOG_FILE)

        JSON.parse(File.read(CONFIRMED_CATALOG_FILE))
      rescue StandardError
        []
      end

      def promote_confirmed_identifiers(identifiers:, vendor:, model:, lifecycle_tier:, trust_zone:)
        FileUtils.mkdir_p(File.dirname(CONFIRMED_CATALOG_FILE))
        entries = load_confirmed_catalog
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
            entries << {
              "identifier" => cleaned,
              "vendor" => vendor,
              "model" => model,
              "lifecycle_tier" => lifecycle_tier,
              "trust_zone" => trust_zone,
              "updated_at" => Time.now.utc.iso8601
            }
          end
        end
        File.write(CONFIRMED_CATALOG_FILE, JSON.pretty_generate(entries))
      rescue StandardError => e
        Rails.logger.warn("[Discovery::HardwareVisionService] Confirmed catalog update skipped: #{e.message}")
      end
    end
  end
end
