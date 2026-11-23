# frozen_string_literal: true

class NetworkSite < ApplicationRecord
  belongs_to :user, optional: true
  has_many :monitored_devices, -> { order(port_index: :asc) }, dependent: :destroy
  has_many :billing_subscriptions, dependent: :destroy

  VALID_SITE_TIERS = %w[day_zero pea garden forest].freeze
  VALID_ENTITLEMENTS = %w[free pro_tier_1 fleet].freeze
  FREE_MAX_PORTS = 15
  MAX_PORTS_M1 = 128

  validates :owner_key, presence: true
  validates :name, presence: true
  validates :slug, presence: true, uniqueness: { scope: :owner_key }
  validates :site_tier, inclusion: { in: VALID_SITE_TIERS }
  validates :entitlement_tier, inclusion: { in: VALID_ENTITLEMENTS }

  def pro_tier_entitled?
    %w[pro_tier_1 multisite_tier_1 fleet].include?(entitlement_tier.to_s.strip.downcase)
  end

  def max_allowed_ports
    pro_tier_entitled? ? MAX_PORTS_M1 : FREE_MAX_PORTS
  end

  def device_capacity_reached?
    monitored_devices.count >= max_allowed_ports
  end

  def muted_feed_slugs_list
    JSON.parse(muted_feed_slugs.presence || '["lg-esphome-iot"]')
  rescue JSON::ParserError
    ["lg-esphome-iot"]
  end

  def muted_feed_slugs_list=(list)
    self.muted_feed_slugs = Array(list).map(&:to_s).uniq.to_json
  end

  def next_available_port_index
    used = monitored_devices.pluck(:port_index).to_set
    (1..max_allowed_ports).find { |idx| !used.include?(idx) }
  end

  def recalculate_tier!
    count = monitored_devices.count
    new_tier = if count == 0
                 "day_zero"
               elsif count <= 3
                 "pea"
               elsif count <= 15
                 "garden"
               else
                 "forest"
               end
    update!(site_tier: new_tier) if site_tier != new_tier
  end
end
