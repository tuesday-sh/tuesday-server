# frozen_string_literal: true

class MonitoredDevice < ApplicationRecord
  belongs_to :network_site

  VALID_CATEGORIES = %w[C1 C2 C3 C4 C5 C6 C7 C8].freeze
  VALID_TRUST_ZONES = %w[z0_core z1_trusted z2_lab z3_iot z4_guest].freeze
  VALID_PORT_STATES = %w[cve_kev eol guessed update ok].freeze
  VALID_CONFIDENCE_TIERS = %w[confirmed provisional_guess opaque_unknown].freeze
  VALID_LIFECYCLE_TIERS = %w[active vintage legacy].freeze

  before_validation :assign_defaults, on: :create

  validates :external_uuid, presence: true, uniqueness: { scope: :network_site_id }
  validates :port_index, presence: true,
                         numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: NetworkSite::MAX_PORTS_M1 },
                         uniqueness: { scope: :network_site_id }
  validates :category_code, inclusion: { in: VALID_CATEGORIES }
  validates :trust_zone, inclusion: { in: VALID_TRUST_ZONES }
  validates :port_state, inclusion: { in: VALID_PORT_STATES }
  validates :confidence_tier, inclusion: { in: VALID_CONFIDENCE_TIERS }
  validates :lifecycle_tier, inclusion: { in: VALID_LIFECYCLE_TIERS }
  validates :short_label, presence: true
  validates :name, presence: true

  after_commit :sync_site_tier

  def purls_list
    parse_json_array(purls)
  end

  def purls_list=(arr)
    self.purls = Array(arr).map(&:to_s).uniq.to_json
  end

  def candidate_models_list
    parse_json_array(candidate_models)
  end

  def candidate_models_list=(arr)
    self.candidate_models = Array(arr).map(&:to_s).uniq.to_json
  end

  def excluded_purl_prefixes_list
    parse_json_array(excluded_purl_prefixes)
  end

  def excluded_purl_prefixes_list=(arr)
    self.excluded_purl_prefixes = Array(arr).map(&:to_s).uniq.to_json
  end

  def version_history_list
    parse_json_array(version_history)
  end

  def version_history_list=(arr)
    self.version_history = Array(arr).to_json
  end

  def to_gold_hash
    {
      id: external_uuid,
      port_index: port_index,
      category_code: category_code,
      port_state: port_state,
      trust_zone: trust_zone,
      asset_tag: asset_tag,
      short_label: short_label,
      name: name,
      vendor: vendor,
      model_number: model_number,
      room_location: room_location,
      version: version,
      target_version: target_version,
      lifecycle_tier: lifecycle_tier,
      purls: purls_list,
      confidence_tier: confidence_tier.to_sym,
      candidate_models: candidate_models_list,
      excluded_purl_prefixes: excluded_purl_prefixes_list,
      version_history: version_history_list
    }
  end

  private

  def assign_defaults
    self.external_uuid = SecureRandom.uuid if external_uuid.blank?
    if port_index.blank? && network_site.present?
      self.port_index = network_site.next_available_port_index
    end
    self.category_code = "C8" if category_code.blank?
    self.trust_zone = "z1_trusted" if trust_zone.blank?
    self.port_state = "ok" if port_state.blank?
    self.confidence_tier = "confirmed" if confidence_tier.blank?
    self.lifecycle_tier = "active" if lifecycle_tier.blank?
    self.short_label = (model_number.presence || name.to_s.split.last || "Node")[0, 14] if short_label.blank?
    self.asset_tag = format("STN-%02d", port_index || 1) if asset_tag.blank?
  end

  def parse_json_array(raw)
    JSON.parse(raw.presence || "[]")
  rescue JSON::ParserError
    []
  end

  def sync_site_tier
    network_site&.recalculate_tier! if network_site && !network_site.destroyed?
  end
end
