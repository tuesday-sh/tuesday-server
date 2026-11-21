# frozen_string_literal: true

require "json"

class SiteNotification < ApplicationRecord
  belongs_to :network_site
  belongs_to :monitored_device, optional: true

  VALID_SURFACES = %w[push bulletin reminder].freeze
  VALID_PRIORITIES = %w[critical high normal low].freeze
  VALID_STATUSES = %w[active seen snoozed completed dismissed expired].freeze
  VALID_PUSH_STATUSES = %w[none pending sent push_seen failed].freeze
  VALID_TRIGGER_TYPES = %w[
    gold_advisory
    maintenance_schedule
    device_lifecycle
    onboarding_nudge
    admin_broadcast
  ].freeze

  validates :rule_id, presence: true
  validates :trigger_type, inclusion: { in: VALID_TRIGGER_TYPES }
  validates :dedup_key, presence: true, uniqueness: { scope: :network_site_id }
  validates :priority, inclusion: { in: VALID_PRIORITIES }
  validates :status, inclusion: { in: VALID_STATUSES }
  validates :push_status, inclusion: { in: VALID_PUSH_STATUSES }
  validates :title, presence: true
  validates :body, presence: true

  scope :unresolved, -> { where(status: %w[active seen snoozed]) }
  scope :updated_since, ->(ts) { ts.present? ? where("updated_at >= ?", ts) : all }

  def surfaces
    parsed = JSON.parse(surfaces_json.presence || "[]")
    parsed.is_a?(Array) ? parsed.map(&:to_s) : []
  rescue JSON::ParserError
    []
  end

  def surfaces=(list)
    clean = Array(list).map(&:to_s).select { |s| VALID_SURFACES.include?(s) }.uniq
    self.surfaces_json = clean.to_json
  end

  def payload
    parsed = JSON.parse(payload_json.presence || "{}")
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def payload=(hash)
    self.payload_json = (hash.is_a?(Hash) ? hash : {}).to_json
  end

  def targets_surface?(surface)
    surfaces.include?(surface.to_s)
  end

  # Shared lifecycle state machine.
  # Swiping an OS push (`push_seen`) does NOT dismiss the in-app Bulletin or Reminder.
  def transition!(action, snooze_minutes: nil)
    now = Time.current
    case action.to_s
    when "push_seen"
      update!(push_status: "push_seen")
    when "seen"
      attrs = { seen_at: seen_at || now }
      attrs[:status] = "seen" if status == "active"
      update!(attrs)
    when "snoozed", "snooze"
      mins = (snooze_minutes || 60).to_i.clamp(5, 43_200)
      update!(status: "snoozed", snoozed_until: now + mins.minutes)
    when "completed", "complete"
      update!(status: "completed", resolved_at: now)
    when "dismissed", "dismiss"
      update!(status: "dismissed", resolved_at: now)
    when "reopen", "active"
      update!(status: "active", snoozed_until: nil, resolved_at: nil)
    else
      raise ArgumentError, "Unsupported notification action: #{action}"
    end
  end

  def to_api_hash
    {
      id: id,
      networkSiteId: network_site_id,
      monitoredDeviceId: monitored_device&.external_uuid || monitored_device_id&.to_s,
      monitoredDeviceLabel: monitored_device&.short_label || monitored_device&.name,
      ruleId: rule_id,
      triggerType: trigger_type,
      dedupKey: dedup_key,
      surfaces: surfaces,
      priority: priority,
      status: status,
      pushStatus: push_status,
      title: title,
      body: body,
      ctaLabel: cta_label,
      deepLinkUri: deep_link_uri,
      payload: payload,
      snoozedUntil: snoozed_until&.utc&.iso8601,
      expiresAt: expires_at&.utc&.iso8601,
      seenAt: seen_at&.utc&.iso8601,
      resolvedAt: resolved_at&.utc&.iso8601,
      createdAt: created_at&.utc&.iso8601,
      updatedAt: updated_at&.utc&.iso8601
    }
  end
end
