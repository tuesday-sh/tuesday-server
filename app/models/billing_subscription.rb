# frozen_string_literal: true

class BillingSubscription < ApplicationRecord
  belongs_to :network_site

  ACTIVE_PLAY_STATES = %w[
    SUBSCRIPTION_STATE_ACTIVE
    SUBSCRIPTION_STATE_IN_GRACE_PERIOD
  ].freeze

  validates :platform, presence: true
  validates :package_name, presence: true
  validates :product_id, presence: true
  validates :purchase_token, presence: true, uniqueness: true
  validates :entitlement_tier, inclusion: { in: NetworkSite::VALID_ENTITLEMENTS }

  def active_entitlement?(now = Time.now.utc)
    return true if ACTIVE_PLAY_STATES.include?(subscription_state)

    if subscription_state == "SUBSCRIPTION_STATE_CANCELED" && expires_at.present?
      return expires_at > now
    end

    false
  end
end
