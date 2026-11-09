# frozen_string_literal: true

require "json"

class NotificationDelivery < ApplicationRecord
  belongs_to :network_site
  belongs_to :monitored_device, optional: true

  VALID_STATUSES = %w[pending sent_fcm delivered_pull opened dismissed].freeze
  VALID_CHANNELS = %w[tuesday_critical_bulletins tuesday_lifecycle_digests].freeze

  validates :client_device_id, presence: true
  validates :bulletin_external_id, presence: true
  validates :title, presence: true
  validates :body, presence: true
  validates :deep_link_uri, presence: true
  validates :delivery_status, inclusion: { in: VALID_STATUSES }
  validates :delivery_channel, inclusion: { in: VALID_CHANNELS }

  def payload
    return {} if payload_json.blank?

    JSON.parse(payload_json)
  rescue JSON::ParserError
    {}
  end

  def to_api_hash
    {
      id: id,
      bulletinExternalId: bulletin_external_id,
      feedSlug: feed_slug,
      bulletinType: bulletin_type,
      isHighSev: is_high_sev,
      brokeThroughMute: broke_through_mute,
      matchedByGuess: matched_by_guess,
      deliveryChannel: delivery_channel,
      deliveryStatus: delivery_status,
      title: title,
      body: body,
      deepLinkUri: deep_link_uri,
      deviceDeepLinkUri: device_deep_link_uri,
      monitoredDeviceId: monitored_device&.external_uuid || monitored_device_id&.to_s,
      monitoredDeviceLabel: monitored_device&.short_label || monitored_device&.name,
      categoryCode: monitored_device&.category_code,
      sentAt: sent_at&.utc&.iso8601,
      deliveredAt: delivered_at&.utc&.iso8601,
      openedAt: opened_at&.utc&.iso8601,
      createdAt: created_at&.utc&.iso8601
    }
  end
end
