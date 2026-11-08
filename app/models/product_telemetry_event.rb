# frozen_string_literal: true

class ProductTelemetryEvent < ApplicationRecord
  belongs_to :network_site, optional: true

  VALID_DOMAINS = %w[discovery inventory bulletin checkup client billing].freeze

  before_validation :assign_defaults, on: :create

  validates :event_uuid, presence: true, uniqueness: true
  validates :event_name, presence: true
  validates :event_domain, inclusion: { in: VALID_DOMAINS }

  def properties
    JSON.parse(properties_json.presence || "{}")
  rescue JSON::ParserError
    {}
  end

  def properties=(hash)
    self.properties_json = (hash || {}).to_json
  end

  def to_telemetry_hash
    {
      eventUuid: event_uuid,
      eventName: event_name,
      eventDomain: event_domain,
      networkSiteId: network_site_id,
      clientPlatform: client_platform,
      appFlavor: app_flavor,
      deviceId: device_id,
      sessionId: session_id,
      targetEntityType: target_entity_type,
      targetEntityId: target_entity_id,
      latencyMs: latency_ms,
      llmTurns: llm_turns,
      totalTokens: total_tokens,
      properties: properties,
      occurredAt: occurred_at&.utc&.iso8601(3)
    }
  end

  private

  def assign_defaults
    self.event_uuid = SecureRandom.uuid if event_uuid.blank?
    if event_domain.blank? && event_name.present?
      prefix = event_name.to_s.split(".").first.to_s.downcase
      self.event_domain = VALID_DOMAINS.include?(prefix) ? prefix : "client"
    end
    self.occurred_at = Time.now.utc if occurred_at.blank?
  end
end
