# frozen_string_literal: true

require "base64"

module Api
  module V1
    # StoreKit 2 (iOS) & Google Play Billing v7 (Android) Entitlement Verification & RTDN Controller.
    #
    # Endpoints:
    # - GET  /api/v1/billing/status
    # - POST /api/v1/billing/verify
    # - POST /api/v1/billing/webhooks/google_play
    class BillingController < ApplicationController
      include Api::V1::SiteScoping
      skip_before_action :verify_authenticity_token, raise: false

      SUPPORTED_SKUS = {
        "sh.tuesday.pro.tier1.monthly" => "pro_tier_1",
        "sh.tuesday.pro.tier1.annual" => "pro_tier_1",
        "sh.tuesday.pro.monthly" => "pro_tier_1",
        "sh.tuesday.pro.yearly" => "pro_tier_1",
        "sh.tuesday.home.tier1.monthly" => "pro_tier_1",
        "sh.tuesday.home.tier1.annual" => "pro_tier_1",
        "sh.tuesday.multisite.tier1.monthly" => "pro_tier_1",
        "sh.tuesday.multisite.tier1.annual" => "pro_tier_1",
        "sh.tuesday.fleet.monthly" => "fleet"
      }.freeze

      def status
        site = current_network_site(auto_create: true)
        active_sub = reconcile_site_entitlement!(site)

        render json: {
          status: "ok",
          entitlementTier: site.entitlement_tier,
          activeSubscriptionSku: active_sub&.product_id,
          subscriptionState: active_sub&.subscription_state,
          expiresAt: active_sub&.expires_at&.utc&.iso8601,
          maxPorts: NetworkSite::MAX_PORTS_M1,
          siteSlug: site.slug,
          checkedAt: Time.now.utc.iso8601
        }
      end

      def verify
        platform = (params[:platform].presence || request.headers["X-Tuesday-Client-Platform"] || "unknown").to_s.downcase
        product_id = params[:product_id].to_s.strip
        package_name = (params[:package_name].presence || Billing::GooglePlayVerifier::DEFAULT_PACKAGE_NAME).to_s.strip
        transaction_token = (params[:transaction_jws].presence || params[:purchase_token].presence).to_s.strip

        if product_id.empty? || transaction_token.empty?
          return render json: {
            error: "product_id and transaction_jws (or purchase_token) are required"
          }, status: :unprocessable_entity
        end

        site = current_network_site(auto_create: true)

        if BillingSubscription.table_exists?
          existing = BillingSubscription.includes(:network_site).find_by(purchase_token: transaction_token)
          if existing && existing.network_site.owner_key != site.owner_key
            return render json: {
              error: "purchase_token is already bound to another account",
              code: "token_already_claimed"
            }, status: :conflict
          end
        end

        if platform == "android"
          verify_android_purchase(
            site: site,
            product_id: product_id,
            package_name: package_name,
            purchase_token: transaction_token
          )
        else
          verify_ios_or_other_purchase(
            site: site,
            platform: platform,
            product_id: product_id,
            transaction_token: transaction_token
          )
        end
      end

      def google_play_webhook
        return render json: { error: "unauthorized_webhook" }, status: :unauthorized unless valid_pubsub_webhook_request?

        decoded = decode_pubsub_payload
        if decoded.nil?
          return render json: { error: "invalid_pubsub_envelope" }, status: :bad_request
        end

        if decoded.key?("testNotification")
          Rails.logger.info("[PlayRTDN] Received Google Play Console testNotification: #{decoded['testNotification'].inspect}")
          return render json: {
            status: "ok",
            event: "test_notification",
            packageName: decoded["packageName"]
          }
        end

        sub_notif = decoded["subscriptionNotification"]
        unless sub_notif.is_a?(Hash) && sub_notif["purchaseToken"].present?
          return render json: { status: "ignored", reason: "non_subscription_event" }
        end

        process_play_subscription_notification(
          package_name: decoded["packageName"].presence || Billing::GooglePlayVerifier::DEFAULT_PACKAGE_NAME,
          notification_type: sub_notif["notificationType"].to_i,
          purchase_token: sub_notif["purchaseToken"].to_s,
          subscription_id: sub_notif["subscriptionId"].to_s
        )
      end

      private

      def verify_android_purchase(site:, product_id:, package_name:, purchase_token:)
        result = Billing::GooglePlayVerifier.verify_subscription_token(
          purchase_token: purchase_token,
          fallback_product_id: product_id,
          package_name: package_name
        )

        unless result.valid
          return render json: {
            error: result.error_message || "Purchase token verification failed",
            code: result.error_code || "verification_failed"
          }, status: :unprocessable_entity
        end

        resolved_sku = result.product_id.presence || product_id
        target_entitlement = result.active ? (SUPPORTED_SKUS[resolved_sku] || "pro_tier_1") : "free"

        if BillingSubscription.table_exists?
          upsert_billing_subscription!(
            site: site,
            platform: "android",
            package_name: package_name,
            product_id: resolved_sku,
            purchase_token: purchase_token,
            entitlement_tier: SUPPORTED_SKUS[resolved_sku] || "pro_tier_1",
            subscription_state: result.subscription_state,
            verification_source: result.verification_source,
            auto_renewing: result.auto_renewing != false,
            is_test_purchase: result.is_test_purchase == true,
            expires_at: result.expires_at,
            external_account_id: result.external_account_id || site.owner_key,
            external_profile_id: result.external_profile_id || site.slug,
            raw_metadata: result.raw_metadata || {}
          )
        end

        unless result.active
          reconcile_site_entitlement!(site)
          return render json: {
            error: "Subscription is no longer active (#{result.subscription_state})",
            code: "subscription_inactive",
            entitlementTier: site.entitlement_tier,
            subscriptionState: result.subscription_state
          }, status: :unprocessable_entity
        end

        site.update!(entitlement_tier: target_entitlement)

        render json: {
          status: "verified",
          platform: "android",
          productId: resolved_sku,
          entitlementTier: target_entitlement,
          subscriptionState: result.subscription_state,
          verificationSource: result.verification_source,
          expiresAt: result.expires_at&.utc&.iso8601,
          maxPorts: NetworkSite::MAX_PORTS_M1,
          siteSlug: site.slug,
          verifiedAt: Time.now.utc.iso8601
        }
      end

      def verify_ios_or_other_purchase(site:, platform:, product_id:, transaction_token:)
        entitlement = SUPPORTED_SKUS[product_id] || "pro_tier_1"

        if BillingSubscription.table_exists?
          upsert_billing_subscription!(
            site: site,
            platform: platform,
            package_name: "sh.tuesday.app",
            product_id: product_id,
            purchase_token: transaction_token,
            entitlement_tier: entitlement,
            subscription_state: "SUBSCRIPTION_STATE_ACTIVE",
            verification_source: "storekit_jws",
            auto_renewing: true,
            is_test_purchase: false,
            expires_at: nil,
            external_account_id: site.owner_key,
            external_profile_id: site.slug,
            raw_metadata: {}
          )
        end

        site.update!(entitlement_tier: entitlement)

        render json: {
          status: "verified",
          platform: platform,
          productId: product_id,
          entitlementTier: entitlement,
          maxPorts: NetworkSite::MAX_PORTS_M1,
          siteSlug: site.slug,
          verifiedAt: Time.now.utc.iso8601
        }
      end

      def process_play_subscription_notification(package_name:, notification_type:, purchase_token:, subscription_id:)
        sub = BillingSubscription.includes(:network_site).find_by(purchase_token: purchase_token) if BillingSubscription.table_exists?

        # Query authoritative state from Google Play Developer API when credentials are live,
        # falling back deterministically to the RTDN notificationType code.
        api_result = Billing::GooglePlayVerifier.verify_subscription_token(
          purchase_token: purchase_token,
          fallback_product_id: subscription_id.presence || sub&.product_id || "sh.tuesday.pro.tier1.annual",
          package_name: package_name
        )

        site = sub&.network_site || locate_site_from_external_ids(api_result.external_account_id, api_result.external_profile_id)
        if site.nil?
          Rails.logger.warn("[PlayRTDN] No matching NetworkSite for purchaseToken prefix #{purchase_token[0, 12]} (type=#{notification_type})")
          return render json: { status: "ignored", reason: "unknown_site" }
        end

        mapped_rtdn_state = Billing::GooglePlayVerifier.state_for_rtdn_type(notification_type)
        effective_state = if api_result.valid && api_result.verification_source.start_with?("google_play")
                            api_result.subscription_state
                          else
                            mapped_rtdn_state || sub&.subscription_state || "SUBSCRIPTION_STATE_ACTIVE"
                          end

        resolved_sku = api_result.product_id.presence || subscription_id.presence || sub&.product_id || "sh.tuesday.pro.tier1.annual"
        effective_expiry = if effective_state == "SUBSCRIPTION_STATE_EXPIRED" || effective_state == "SUBSCRIPTION_STATE_REVOKED"
                             [api_result.expires_at, Time.now.utc].compact.min
                           else
                             api_result.expires_at || sub&.expires_at
                           end

        if BillingSubscription.table_exists?
          upsert_billing_subscription!(
            site: site,
            platform: "android",
            package_name: package_name,
            product_id: resolved_sku,
            purchase_token: purchase_token,
            entitlement_tier: SUPPORTED_SKUS[resolved_sku] || "pro_tier_1",
            subscription_state: effective_state,
            verification_source: "rtdn_webhook",
            auto_renewing: !%w[SUBSCRIPTION_STATE_CANCELED SUBSCRIPTION_STATE_EXPIRED SUBSCRIPTION_STATE_REVOKED].include?(effective_state),
            is_test_purchase: api_result.is_test_purchase == true || (sub&.is_test_purchase == true),
            expires_at: effective_expiry,
            external_account_id: api_result.external_account_id || site.owner_key,
            external_profile_id: api_result.external_profile_id || site.slug,
            raw_metadata: api_result.raw_metadata.presence || { "notificationType" => notification_type }
          )
        end

        reconcile_site_entitlement!(site, force_recompute: true)

        render json: {
          status: "processed",
          notificationType: notification_type,
          subscriptionState: effective_state,
          entitlementTier: site.entitlement_tier,
          siteSlug: site.slug
        }
      end

      def upsert_billing_subscription!(
        site:,
        platform:,
        package_name:,
        product_id:,
        purchase_token:,
        entitlement_tier:,
        subscription_state:,
        verification_source:,
        auto_renewing:,
        is_test_purchase:,
        expires_at:,
        external_account_id:,
        external_profile_id:,
        raw_metadata:
      )
        record = BillingSubscription.find_or_initialize_by(purchase_token: purchase_token)
        record.assign_attributes(
          network_site: site,
          platform: platform,
          package_name: package_name,
          product_id: product_id,
          entitlement_tier: entitlement_tier,
          subscription_state: subscription_state,
          verification_source: verification_source,
          auto_renewing: auto_renewing,
          is_test_purchase: is_test_purchase,
          expires_at: expires_at,
          external_account_id: external_account_id,
          external_profile_id: external_profile_id,
          last_verified_at: Time.now.utc,
          raw_metadata_json: raw_metadata.to_json
        )
        record.save!
        record
      end

      def reconcile_site_entitlement!(site, force_recompute: false)
        return nil unless BillingSubscription.table_exists?

        subs = site.billing_subscriptions.order(updated_at: :desc).to_a
        return nil if subs.empty? && !force_recompute

        now = Time.now.utc
        subs.each do |s|
          if s.expires_at.present? && s.expires_at <= now && BillingSubscription::ACTIVE_PLAY_STATES.include?(s.subscription_state)
            s.update!(subscription_state: "SUBSCRIPTION_STATE_EXPIRED", auto_renewing: false)
          end
        end

        active_sub = subs.find { |s| s.active_entitlement?(now) }
        desired_tier = active_sub ? active_sub.entitlement_tier : "free"
        site.update!(entitlement_tier: desired_tier) if site.entitlement_tier != desired_tier
        active_sub
      end

      def locate_site_from_external_ids(external_account_id, external_profile_id)
        return nil if external_account_id.to_s.strip.empty?

        owner_key = external_account_id.to_s.strip
        slug = external_profile_id.to_s.strip.presence || "skyway-lab"
        NetworkSite.find_by(owner_key: owner_key, slug: slug) || NetworkSite.find_by(owner_key: owner_key)
      end

      def decode_pubsub_payload
        raw_data = params.dig(:message, :data).to_s.strip
        return JSON.parse(request.raw_post) if raw_data.empty? && request.raw_post.present? && params[:subscriptionNotification].present?
        return nil if raw_data.empty?

        JSON.parse(Base64.decode64(raw_data))
      rescue ArgumentError, JSON::ParserError
        nil
      end

      def valid_pubsub_webhook_request?
        expected_secret = ENV["GOOGLE_PLAY_WEBHOOK_SECRET"].to_s.strip
        return true if expected_secret.empty?

        provided = params[:token].to_s.strip.presence ||
                   request.headers["Authorization"].to_s[/\ABearer\s+(.+)\z/i, 1].to_s.strip
        ActiveSupport::SecurityUtils.secure_compare(provided, expected_secret)
      end
    end
  end
end
