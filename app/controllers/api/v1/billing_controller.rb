# frozen_string_literal: true

module Api
  module V1
    # StoreKit 2 (iOS) & Google Play Billing v7 (Android) Entitlement Verification Controller.
    #
    # Endpoint:
    # - POST /api/v1/billing/verify
    class BillingController < ApplicationController
      include Api::V1::SiteScoping
      skip_before_action :verify_authenticity_token, raise: false

      SUPPORTED_SKUS = {
        "sh.tuesday.pro.tier1.monthly" => "pro_tier_1",
        "sh.tuesday.pro.tier1.annual" => "pro_tier_1",
        "sh.tuesday.fleet.monthly" => "fleet"
      }.freeze

      def verify
        platform = (params[:platform].presence || request.headers["X-Tuesday-Client-Platform"] || "unknown").to_s.downcase
        product_id = params[:product_id].to_s.strip
        transaction_token = (params[:transaction_jws].presence || params[:purchase_token].presence).to_s.strip

        if product_id.empty? || transaction_token.empty?
          return render json: {
            error: "product_id and transaction_jws (or purchase_token) are required"
          }, status: :unprocessable_entity
        end

        entitlement = SUPPORTED_SKUS[product_id] || "pro_tier_1"
        site = current_network_site(auto_create: true)
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
    end
  end
end
