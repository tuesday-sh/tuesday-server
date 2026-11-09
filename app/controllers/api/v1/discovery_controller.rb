# frozen_string_literal: true

module Api
  module V1
    # Hosted Hardware Vision Discovery Proxy Controller.
    #
    # Endpoints:
    # - POST /api/v1/discovery/analyze
    # - POST /api/v1/discovery/confirm
    #
    # PRIVACY COMPLIANCE INVARIANT:
    # Camera frames in `images_base64` are filtered from Rails logs (`[FILTERED]`),
    # processed strictly in ephemeral RAM during the upstream LLM call, and never
    # persisted to disk, databases, or object storage.
    class DiscoveryController < ApplicationController
      include Api::V1::SiteScoping
      skip_before_action :verify_authenticity_token, raise: false

      MAX_IMAGES_PER_TURN = 2
      MAX_TOTAL_BASE64_BYTES = 850_000 # ~620 KB raw JPEG budget
      ANON_HOURLY_LIMIT = 30
      AUTH_HOURLY_LIMIT = 300

      before_action :authenticate_and_rate_limit!, except: [:livetail, :sessions]
      before_action :authenticate_livetail!, only: [:livetail, :sessions]

      # POST /api/v1/discovery/analyze
      def analyze
        raw_images = Array(params[:images_base64] || params[:images])
        if raw_images.size > MAX_IMAGES_PER_TURN
          return render json: {
            error: "Too many images in a single turn (max #{MAX_IMAGES_PER_TURN})"
          }, status: :payload_too_large
        end

        total_b64_bytes = raw_images.sum { |img| img.to_s.bytesize }
        if total_b64_bytes > MAX_TOTAL_BASE64_BYTES
          return render json: {
            error: "Image payload exceeds maximum ephemeral transit size (#{MAX_TOTAL_BASE64_BYTES} bytes)"
          }, status: :payload_too_large
        end

        previous_guess = if params[:previous_guess].respond_to?(:to_unsafe_h)
                           params[:previous_guess].to_unsafe_h
                         elsif params[:previous_guess].is_a?(Hash)
                           params[:previous_guess]
                         end

        debug_mode = ActiveModel::Type::Boolean.new.cast(params[:debug] || request.headers["X-Tuesday-Debug"]) || false

        payload = Discovery::HardwareVisionService.analyze(
          session_id: params[:session_id].presence || "tuesday-#{@client_platform}-#{SecureRandom.hex(4)}",
          turn_index: (params[:turn_index] || 1).to_i,
          client_platform: @client_platform,
          device_id: @device_id,
          network_site_id: current_network_site(auto_create: false)&.id,
          initial_mode: params[:initial_mode].presence || "photo_wizard",
          provider_override: params[:provider_override].presence || params[:provider_preference].presence || "auto",
          previous_guess: previous_guess,
          extracted_identifiers: params[:extracted_identifiers] || [],
          user_clue_notes: Array(params[:user_clue_notes]),
          images_base64: raw_images,
          debug: debug_mode
        )

        response.set_header("X-Tuesday-Image-Retention", "none_ephemeral_ram_only")
        render json: payload
      ensure
        raw_images&.clear if raw_images.respond_to?(:clear)
      end

      # GET /api/v1/discovery/livetail
      def livetail
        limit = (params[:limit] || params[:n] || 15).to_i.clamp(1, 100)
        entries = Telemetry::HostedAiLogger.read_recent_livetail(limit: limit)

        if params[:session_id].present?
          entries = entries.select { |e| e["sessionId"].to_s == params[:session_id].to_s }
        end
        if params[:device_id].present?
          entries = entries.select { |e| e["deviceId"].to_s == params[:device_id].to_s }
        end

        if params[:format].to_s == "text"
          text_body = entries.map { |e| e["debugLogText"] }.compact.join("\n#{'=' * 80}\n")
          render plain: text_body.presence || "No vision debug livetail entries recorded yet.\n"
          return
        end

        if ActiveModel::Type::Boolean.new.cast(params[:stream])
          response.headers["Content-Type"] = "text/event-stream"
          response.headers["Cache-Control"] = "no-cache"
          response.headers["X-Accel-Buffering"] = "no"
          sse_body = entries.map { |e| "event: vision_turn\ndata: #{JSON.generate(e)}\n\n" }.join
          render plain: sse_body
          return
        end

        payload = {
          status: "ok",
          count: entries.size,
          entries: entries
        }
        unless Rails.env.production?
          payload[:livetailLogPath] = Telemetry::HostedAiLogger.livetail_log_path
          payload[:livetailJsonlPath] = Telemetry::HostedAiLogger.livetail_jsonl_path
        end

        render json: payload
      end

      # GET /api/v1/discovery/sessions
      def sessions
        limit = (params[:limit] || 20).to_i.clamp(1, 100)
        scope = DiscoverySession.includes(:discovery_turns).order(updated_at: :desc)
        scope = scope.where(session_id: params[:session_id].to_s) if params[:session_id].present?
        scope = scope.where(resolution_status: params[:resolution_status].to_s) if params[:resolution_status].present?
        scope = scope.where(needs_catalog_review: true) if ActiveModel::Type::Boolean.new.cast(params[:needs_catalog_review])

        records = scope.limit(limit).map(&:to_funnel_hash)
        render json: {
          status: "ok",
          count: records.size,
          sessions: records
        }
      end

      # POST /api/v1/discovery/confirm (and POST /api/v1/discovery/resolve)
      def confirm
        resolution_status = params[:resolution_status].presence || "confirmed_candidate"
        confirmed_vendor = params[:confirmed_vendor].to_s.strip
        confirmed_model = params[:confirmed_model].to_s.strip

        # When confirming a candidate directly, vendor & model are required.
        # For saved_best_guess, fallback to inferred_vendor / inferred_model or "Unknown Vendor" / "Unidentified Hardware".
        if resolution_status == "confirmed_candidate" && (confirmed_vendor.empty? || confirmed_model.empty?)
          return render json: { error: "confirmed_vendor and confirmed_model are required" }, status: :unprocessable_entity
        elsif resolution_status == "saved_best_guess"
          confirmed_vendor = params[:inferred_vendor].to_s.strip.presence || "Unknown Vendor" if confirmed_vendor.empty?
          confirmed_model = params[:inferred_model].to_s.strip.presence || "Unidentified Hardware" if confirmed_model.empty?
        end

        site = current_network_site(auto_create: false)
        enrolled_device = if %w[confirmed_candidate saved_best_guess pivoted_to_barcode pivoted_to_manual].include?(resolution_status) &&
                             confirmed_vendor.present? && confirmed_model.present?
                            persist_confirmed_device_to_site(
                              confirmed_vendor: confirmed_vendor,
                              confirmed_model: confirmed_model,
                              resolution_status: resolution_status,
                              lifecycle_tier: params[:suggested_lifecycle_tier].presence || "active",
                              trust_zone: params[:suggested_trust_zone].presence || "z1_trusted"
                            )
                          end

        selected_rank = params[:selected_candidate_rank].present? ? params[:selected_candidate_rank].to_i : (resolution_status == "confirmed_candidate" ? 0 : nil)

        record = Discovery::HardwareVisionService.record_confirmation!(
          session_id: params[:session_id].presence || "tuesday-#{@client_platform}",
          client_platform: @client_platform,
          device_id: @device_id,
          network_site_id: enrolled_device&.network_site_id || site&.id,
          monitored_device_id: enrolled_device&.id,
          inferred_vendor: params[:inferred_vendor],
          inferred_model: params[:inferred_model],
          confirmed_vendor: confirmed_vendor,
          confirmed_model: confirmed_model,
          was_edited: ActiveModel::Type::Boolean.new.cast(params[:was_edited]) || false,
          resolution_status: resolution_status,
          selected_candidate_rank: selected_rank,
          initial_mode: params[:initial_mode].presence || "photo_wizard",
          final_mode: params[:final_mode].presence,
          extracted_identifiers: Array(params[:extracted_identifiers]),
          user_clue_notes: Array(params[:user_clue_notes]),
          suggested_lifecycle_tier: params[:suggested_lifecycle_tier].presence || "active",
          suggested_trust_zone: params[:suggested_trust_zone].presence || "z1_trusted"
        )

        render json: {
          status: resolution_status == "confirmed_candidate" ? "confirmed" : resolution_status,
          resolutionStatus: record["resolutionStatus"],
          sessionId: record["sessionId"],
          selectedCandidateRank: record["selectedCandidateRank"],
          confirmedVendor: record["confirmedVendor"],
          confirmedModel: record["confirmedModel"],
          wasEdited: record["wasEdited"],
          needsCatalogReview: record["needsCatalogReview"],
          enrolledDevice: enrolled_device&.to_gold_hash,
          privacyAttestation: Discovery::HardwareVisionService::PRIVACY_ATTESTATION
        }
      end
      alias_method :resolve, :confirm

      private

      def persist_confirmed_device_to_site(confirmed_vendor:, confirmed_model:, lifecycle_tier:, trust_zone:, resolution_status: "confirmed_candidate")
        return nil if ActiveModel::Type::Boolean.new.cast(params[:enroll]) == false

        site = current_network_site(auto_create: true)
        return nil if site.nil?

        existing = site.monitored_devices.find_by(vendor: confirmed_vendor, model_number: confirmed_model)
        return existing if existing

        next_port = params[:port_index].present? ? params[:port_index].to_i : site.next_available_port_index
        return nil if next_port.nil? || next_port > NetworkSite::MAX_PORTS_M1

        ver = params[:version].presence || "1.0.0"
        resolved_gold = Discovery::HardwareVisionService.resolve_gold_device_identity(
          vendor: confirmed_vendor,
          model: confirmed_model,
          version: ver
        )

        is_guess = (resolution_status == "saved_best_guess")
        conf_tier = is_guess ? "provisional_guess" : "confirmed"
        p_state = params[:port_state].presence || (is_guess ? "guessed" : "ok")
        resolved_category = params[:category_code].presence || resolved_gold[:category_code] || "C8"

        device = site.monitored_devices.build(
          port_index: next_port,
          category_code: resolved_category,
          trust_zone: MonitoredDevice::VALID_TRUST_ZONES.include?(trust_zone) ? trust_zone : "z1_trusted",
          port_state: MonitoredDevice::VALID_PORT_STATES.include?(p_state) ? p_state : "ok",
          confidence_tier: conf_tier,
          short_label: confirmed_model[0, 14],
          name: params[:name].presence || "#{confirmed_vendor} #{confirmed_model}".strip,
          vendor: confirmed_vendor,
          model_number: confirmed_model,
          room_location: params[:room_location].presence || "Rack / Room",
          version: ver,
          lifecycle_tier: MonitoredDevice::VALID_LIFECYCLE_TIERS.include?(lifecycle_tier) ? lifecycle_tier : "active"
        )
        device.purls_list = Array(params[:purls].presence || resolved_gold[:purls])
        device.candidate_models_list = Array(params[:candidate_models].presence || (is_guess ? [confirmed_model] : []))
        device.save ? device : nil
      end

      def authenticate_livetail!
        bearer_token = request.headers["Authorization"].to_s[/\ABearer\s+(.+)\z/i, 1]&.strip
        livetail_header = request.headers["X-Tuesday-Livetail-Token"].to_s.strip
        supplied_token = livetail_header.presence || bearer_token.to_s
        expected_pilot_token = ENV.fetch("TUESDAY_PILOT_CLIENT_TOKEN", "tuesday-pilot-v1-public-client-token")

        # 1. Check dedicated TUESDAY_LIVETAIL_TOKEN (constant-time comparison, never matches public pilot token)
        expected_livetail_token = ENV["TUESDAY_LIVETAIL_TOKEN"].to_s.strip
        if expected_livetail_token.length >= 16 &&
           supplied_token.present? &&
           supplied_token != expected_pilot_token &&
           ActiveSupport::SecurityUtils.secure_compare(supplied_token, expected_livetail_token)
          return
        end

        # 2. Check database ApiKey (excluding public pilot client token)
        if supplied_token.present? && supplied_token != expected_pilot_token && defined?(ApiKey) && ApiKey.table_exists?
          api_key = ApiKey.find_by(token: supplied_token)
          return if api_key.present?
        end

        # 3. Local dev / Tailscale subnet allowance ONLY in development/test (unless ?require_auth=true)
        if (Rails.env.development? || Rails.env.test?) && !ActiveModel::Type::Boolean.new.cast(params[:require_auth])
          ip = request.remote_ip.to_s
          if ip == "127.0.0.1" || ip == "::1" || ip.start_with?("192.168.", "10.", "100.")
            return
          end
        end

        render json: {
          error: "Unauthorized: livetail requires a valid X-Tuesday-Livetail-Token or admin Authorization Bearer token"
        }, status: :unauthorized
      end

      def authenticate_and_rate_limit!
        @client_platform = (request.headers["X-Tuesday-Client-Platform"].presence || params[:client_platform].presence || "unknown").to_s.downcase
        @device_id = (request.headers["X-Tuesday-Device-ID"].presence || params[:device_id].presence).to_s.strip

        bearer_token = request.headers["Authorization"].to_s[/\ABearer\s+(.+)\z/i, 1]&.strip
        pilot_header = request.headers["X-Tuesday-Pilot-Token"].to_s.strip
        expected_pilot_token = ENV.fetch("TUESDAY_PILOT_CLIENT_TOKEN", "tuesday-pilot-v1-public-client-token")

        @authenticated_api_key = nil
        if bearer_token.present? && bearer_token != expected_pilot_token && defined?(ApiKey) && ApiKey.table_exists?
          @authenticated_api_key = ApiKey.find_by(token: bearer_token)
        end

        if @authenticated_api_key.nil?
          # Anonymous device session mode requires either X-Tuesday-Device-ID or valid pilot token
          if @device_id.empty? && bearer_token != expected_pilot_token && pilot_header != expected_pilot_token
            render json: {
              error: "Missing X-Tuesday-Device-ID header or Authorization token"
            }, status: :unauthorized
            return
          end
          @device_id = "anon-#{request.remote_ip}" if @device_id.empty?
        else
          @device_id = "user-#{@authenticated_api_key.bearer_id}" if @device_id.empty?
        end

        enforce_rate_limit!
      end

      def enforce_rate_limit!
        limit = @authenticated_api_key ? AUTH_HOURLY_LIMIT : ANON_HOURLY_LIMIT
        bucket = Time.now.utc.strftime("%Y%m%d%H")
        cache_key = "discovery_rate:#{@device_id}:#{bucket}"

        current_count = Rails.cache.read(cache_key).to_i + 1
        Rails.cache.write(cache_key, current_count, expires_in: 1.hour)

        response.set_header("X-RateLimit-Limit", limit.to_s)
        response.set_header("X-RateLimit-Remaining", [limit - current_count, 0].max.to_s)

        return unless current_count > limit

        render json: {
          error: "Hourly hardware scan rate limit exceeded (#{limit}/hr). Sign in or wait until the next hour."
        }, status: :too_many_requests
      end
    end
  end
end
