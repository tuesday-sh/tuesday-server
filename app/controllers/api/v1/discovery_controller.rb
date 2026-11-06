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

      before_action :authenticate_and_rate_limit!

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

        payload = Discovery::HardwareVisionService.analyze(
          session_id: params[:session_id].presence || "tuesday-#{@client_platform}-#{SecureRandom.hex(4)}",
          turn_index: (params[:turn_index] || 1).to_i,
          client_platform: @client_platform,
          device_id: @device_id,
          provider_override: params[:provider_override].presence || params[:provider_preference].presence || "auto",
          previous_guess: previous_guess,
          extracted_identifiers: params[:extracted_identifiers] || [],
          user_clue_notes: Array(params[:user_clue_notes]),
          images_base64: raw_images
        )

        response.set_header("X-Tuesday-Image-Retention", "none_ephemeral_ram_only")
        render json: payload
      ensure
        raw_images&.clear if raw_images.respond_to?(:clear)
      end

      # POST /api/v1/discovery/confirm
      def confirm
        confirmed_vendor = params[:confirmed_vendor].to_s.strip
        confirmed_model = params[:confirmed_model].to_s.strip

        if confirmed_vendor.empty? || confirmed_model.empty?
          return render json: { error: "confirmed_vendor and confirmed_model are required" }, status: :unprocessable_entity
        end

        record = Discovery::HardwareVisionService.record_confirmation!(
          session_id: params[:session_id].presence || "tuesday-#{@client_platform}",
          client_platform: @client_platform,
          device_id: @device_id,
          inferred_vendor: params[:inferred_vendor],
          inferred_model: params[:inferred_model],
          confirmed_vendor: confirmed_vendor,
          confirmed_model: confirmed_model,
          was_edited: ActiveModel::Type::Boolean.new.cast(params[:was_edited]) || false,
          extracted_identifiers: Array(params[:extracted_identifiers]),
          suggested_lifecycle_tier: params[:suggested_lifecycle_tier].presence || "active",
          suggested_trust_zone: params[:suggested_trust_zone].presence || "z1_trusted"
        )

        enrolled_device = persist_confirmed_device_to_site(
          confirmed_vendor: confirmed_vendor,
          confirmed_model: confirmed_model,
          lifecycle_tier: params[:suggested_lifecycle_tier].presence || "active",
          trust_zone: params[:suggested_trust_zone].presence || "z1_trusted"
        )

        render json: {
          status: "confirmed",
          sessionId: record["sessionId"],
          confirmedVendor: record["confirmedVendor"],
          confirmedModel: record["confirmedModel"],
          wasEdited: record["wasEdited"],
          enrolledDevice: enrolled_device&.to_gold_hash,
          privacyAttestation: Discovery::HardwareVisionService::PRIVACY_ATTESTATION
        }
      end

      private

      def persist_confirmed_device_to_site(confirmed_vendor:, confirmed_model:, lifecycle_tier:, trust_zone:)
        return nil if ActiveModel::Type::Boolean.new.cast(params[:enroll]) == false

        site = current_network_site(auto_create: true)
        return nil if site.nil?

        existing = site.monitored_devices.find_by(vendor: confirmed_vendor, model_number: confirmed_model)
        return existing if existing

        next_port = params[:port_index].present? ? params[:port_index].to_i : site.next_available_port_index
        return nil if next_port.nil? || next_port > NetworkSite::MAX_PORTS_M1

        vendor_slug = confirmed_vendor.to_s.parameterize.presence || "generic"
        model_slug = confirmed_model.to_s.parameterize.presence || "device"
        ver = params[:version].presence || "1.0.0"

        device = site.monitored_devices.build(
          port_index: next_port,
          category_code: params[:category_code].presence || "C8",
          trust_zone: MonitoredDevice::VALID_TRUST_ZONES.include?(trust_zone) ? trust_zone : "z1_trusted",
          port_state: params[:port_state].presence || "ok",
          confidence_tier: "confirmed",
          short_label: confirmed_model[0, 14],
          name: params[:name].presence || "#{confirmed_vendor} #{confirmed_model}".strip,
          vendor: confirmed_vendor,
          model_number: confirmed_model,
          room_location: params[:room_location].presence || "Rack / Room",
          version: ver,
          lifecycle_tier: MonitoredDevice::VALID_LIFECYCLE_TIERS.include?(lifecycle_tier) ? lifecycle_tier : "active"
        )
        device.purls_list = Array(params[:purls].presence || ["pkg:generic/#{vendor_slug}/#{model_slug}@#{ver}"])
        device.save ? device : nil
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
