# frozen_string_literal: true

require "cgi"
require "json"
require "net/http"
require "time"
require "uri"

module Billing
  class GooglePlayVerifier
    DEFAULT_PACKAGE_NAME = "sh.tuesday.app"
    ALLOWED_PACKAGE_NAMES = %w[sh.tuesday.app sh.tuesday.pro sh.tuesday.home].freeze
    ANDROID_PUBLISHER_SCOPE = "https://www.googleapis.com/auth/androidpublisher"
    METADATA_TOKEN_URL = "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token?scopes=#{ANDROID_PUBLISHER_SCOPE}".freeze

    # Google Play Real-Time Developer Notification (RTDN) SubscriptionNotification.notificationType codes
    RTDN_NOTIFICATION_STATES = {
      1 => "SUBSCRIPTION_STATE_ACTIVE",          # SUBSCRIPTION_RECOVERED
      2 => "SUBSCRIPTION_STATE_ACTIVE",          # SUBSCRIPTION_RENEWED
      3 => "SUBSCRIPTION_STATE_CANCELED",        # SUBSCRIPTION_CANCELED (remains entitled until expires_at)
      4 => "SUBSCRIPTION_STATE_ACTIVE",          # SUBSCRIPTION_PURCHASED
      5 => "SUBSCRIPTION_STATE_ON_HOLD",         # SUBSCRIPTION_ON_HOLD
      6 => "SUBSCRIPTION_STATE_IN_GRACE_PERIOD", # SUBSCRIPTION_IN_GRACE_PERIOD
      7 => "SUBSCRIPTION_STATE_ACTIVE",          # SUBSCRIPTION_RESTARTED
      10 => "SUBSCRIPTION_STATE_PAUSED",         # SUBSCRIPTION_PAUSED
      12 => "SUBSCRIPTION_STATE_REVOKED",        # SUBSCRIPTION_REVOKED
      13 => "SUBSCRIPTION_STATE_EXPIRED"         # SUBSCRIPTION_EXPIRED
    }.freeze

    VerificationResult = Struct.new(
      :valid,
      :active,
      :subscription_state,
      :product_id,
      :expires_at,
      :auto_renewing,
      :is_test_purchase,
      :external_account_id,
      :external_profile_id,
      :verification_source,
      :error_code,
      :error_message,
      :raw_metadata,
      keyword_init: true
    )

    @token_mutex = Mutex.new
    @cached_access_token = nil
    @cached_token_expires_at = Time.at(0).utc

    class << self
      def verify_subscription_token(purchase_token:, fallback_product_id:, package_name: DEFAULT_PACKAGE_NAME)
        clean_pkg = ALLOWED_PACKAGE_NAMES.include?(package_name.to_s) ? package_name.to_s : DEFAULT_PACKAGE_NAME

        if sandbox_token?(purchase_token)
          return verify_sandbox_token(fallback_product_id: fallback_product_id)
        end

        access_token = fetch_access_token
        if access_token.nil?
          return handle_unconfigured_credentials(fallback_product_id: fallback_product_id)
        end

        uri = URI.parse(
          "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/#{CGI.escape(clean_pkg)}/purchases/subscriptionsv2/tokens/#{CGI.escape(purchase_token)}"
        )
        response = perform_json_get(uri, access_token)
        code = response.code.to_i
        payload = parse_json(response.body)

        if code == 200
          build_result_from_play_v2(
            payload: payload,
            fallback_product_id: fallback_product_id,
            package_name: clean_pkg,
            purchase_token: purchase_token,
            access_token: access_token
          )
        elsif code == 400 || code == 404 || code == 410
          VerificationResult.new(
            valid: false,
            active: false,
            subscription_state: "SUBSCRIPTION_STATE_INVALID",
            product_id: fallback_product_id,
            verification_source: "google_play_api",
            error_code: "invalid_purchase_token",
            error_message: payload.dig("error", "message") || "Google Play rejected purchase_token (HTTP #{code})",
            raw_metadata: payload
          )
        else
          Rails.logger.warn("[GooglePlayVerifier] Play API returned HTTP #{code}: #{response.body.to_s[0, 300]}")
          VerificationResult.new(
            valid: false,
            active: false,
            subscription_state: "SUBSCRIPTION_STATE_UNVERIFIED",
            product_id: fallback_product_id,
            verification_source: "google_play_api",
            error_code: "play_api_unavailable_#{code}",
            error_message: payload.dig("error", "message") || "Google Play verification unavailable (HTTP #{code})",
            raw_metadata: payload
          )
        end
      rescue StandardError => e
        Rails.logger.error("[GooglePlayVerifier] Verification exception: #{e.class}: #{e.message}")
        VerificationResult.new(
          valid: false,
          active: false,
          subscription_state: "SUBSCRIPTION_STATE_ERROR",
          product_id: fallback_product_id,
          verification_source: "google_play_api",
          error_code: "verifier_network_error",
          error_message: e.message,
          raw_metadata: {}
        )
      end

      def sandbox_token?(token)
        token.to_s.start_with?("gp_sandbox_", "gp_token_")
      end

      def sandbox_allowed?
        return true if Rails.env.test? || Rails.env.development?

        ENV.fetch("ALLOW_SANDBOX_BILLING", "false") == "true"
      end

      def state_for_rtdn_type(notification_type)
        RTDN_NOTIFICATION_STATES[notification_type.to_i]
      end

      private

      def verify_sandbox_token(fallback_product_id:)
        unless sandbox_allowed?
          return VerificationResult.new(
            valid: false,
            active: false,
            subscription_state: "SUBSCRIPTION_STATE_INVALID",
            product_id: fallback_product_id,
            verification_source: "sandbox_rejected",
            error_code: "sandbox_not_allowed",
            error_message: "Sandbox purchase tokens are disabled in production",
            raw_metadata: {}
          )
        end

        VerificationResult.new(
          valid: true,
          active: true,
          subscription_state: "SUBSCRIPTION_STATE_ACTIVE",
          product_id: fallback_product_id,
          expires_at: 30.days.from_now.utc,
          auto_renewing: true,
          is_test_purchase: true,
          verification_source: "sandbox",
          raw_metadata: { "sandbox" => true }
        )
      end

      def handle_unconfigured_credentials(fallback_product_id:)
        if sandbox_allowed?
          return VerificationResult.new(
            valid: true,
            active: true,
            subscription_state: "SUBSCRIPTION_STATE_ACTIVE",
            product_id: fallback_product_id,
            expires_at: 30.days.from_now.utc,
            auto_renewing: true,
            is_test_purchase: true,
            verification_source: "local_unconfigured_fallback",
            raw_metadata: {}
          )
        end

        VerificationResult.new(
          valid: false,
          active: false,
          subscription_state: "SUBSCRIPTION_STATE_UNVERIFIED",
          product_id: fallback_product_id,
          verification_source: "missing_credentials",
          error_code: "missing_gcp_credentials",
          error_message: "Google Play Developer API credentials unavailable",
          raw_metadata: {}
        )
      end

      def build_result_from_play_v2(payload:, fallback_product_id:, package_name:, purchase_token:, access_token:)
        state = payload["subscriptionState"].to_s.presence || "SUBSCRIPTION_STATE_UNSPECIFIED"
        line_item = Array(payload["lineItems"]).first || {}
        resolved_sku = line_item["productId"].to_s.presence || fallback_product_id
        expires_at = parse_time(line_item["expiryTime"])
        auto_renewing = line_item.dig("autoRenewingPlan", "autoRenewEnabled") == true
        is_test = payload.key?("testPurchase")
        ext_ids = payload["externalAccountIdentifiers"] || {}
        ext_account = ext_ids["obfuscatedExternalAccountId"].to_s.presence
        ext_profile = ext_ids["obfuscatedExternalProfileId"].to_s.presence

        if payload["acknowledgementState"] == "ACKNOWLEDGEMENT_STATE_PENDING" && resolved_sku.present?
          acknowledge_subscription_safely(
            package_name: package_name,
            product_id: resolved_sku,
            purchase_token: purchase_token,
            access_token: access_token
          )
        end

        is_active = BillingSubscription::ACTIVE_PLAY_STATES.include?(state) ||
                    (state == "SUBSCRIPTION_STATE_CANCELED" && expires_at.present? && expires_at > Time.now.utc)

        VerificationResult.new(
          valid: true,
          active: is_active,
          subscription_state: state,
          product_id: resolved_sku,
          expires_at: expires_at,
          auto_renewing: auto_renewing,
          is_test_purchase: is_test,
          external_account_id: ext_account,
          external_profile_id: ext_profile,
          verification_source: is_test ? "google_play_license_test" : "google_play_api",
          raw_metadata: payload
        )
      end

      def acknowledge_subscription_safely(package_name:, product_id:, purchase_token:, access_token:)
        ack_uri = URI.parse(
          "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/#{CGI.escape(package_name)}/purchases/subscriptions/#{CGI.escape(product_id)}/tokens/#{CGI.escape(purchase_token)}:acknowledge"
        )
        http = Net::HTTP.new(ack_uri.host, ack_uri.port)
        http.use_ssl = true
        http.open_timeout = 4
        http.read_timeout = 5
        req = Net::HTTP::Post.new(ack_uri.request_uri)
        req["Authorization"] = "Bearer #{access_token}"
        req["Content-Type"] = "application/json"
        req.body = "{}"
        http.request(req)
      rescue StandardError => e
        Rails.logger.warn("[GooglePlayVerifier] Server-side acknowledge warning: #{e.message}")
      end

      def fetch_access_token
        explicit = ENV["GOOGLE_PLAY_ACCESS_TOKEN"].to_s.strip
        return explicit if explicit.present?
        return nil if Rails.env.test?

        @token_mutex.synchronize do
          if @cached_access_token.present? && @cached_token_expires_at > (Time.now.utc + 60)
            return @cached_access_token
          end

          uri = URI.parse(METADATA_TOKEN_URL)
          http = Net::HTTP.new(uri.host, uri.port)
          http.open_timeout = 2
          http.read_timeout = 2
          req = Net::HTTP::Get.new(uri.request_uri)
          req["Metadata-Flavor"] = "Google"
          res = http.request(req)
          return nil unless res.code.to_i == 200

          body = parse_json(res.body)
          token = body["access_token"].to_s.strip
          return nil if token.empty?

          expires_in = body.fetch("expires_in", 1800).to_i
          @cached_access_token = token
          @cached_token_expires_at = Time.now.utc + expires_in
          @cached_access_token
        end
      rescue StandardError
        nil
      end

      def perform_json_get(uri, access_token)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 5
        http.read_timeout = 8
        req = Net::HTTP::Get.new(uri.request_uri)
        req["Authorization"] = "Bearer #{access_token}"
        req["Accept"] = "application/json"
        http.request(req)
      end

      def parse_json(raw)
        JSON.parse(raw.to_s)
      rescue JSON::ParserError
        {}
      end

      def parse_time(iso_str)
        return nil if iso_str.to_s.strip.empty?

        Time.iso8601(iso_str.to_s).utc
      rescue ArgumentError
        nil
      end
    end
  end
end
