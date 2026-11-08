# frozen_string_literal: true

class DiscoverySession < ApplicationRecord
  belongs_to :network_site, optional: true
  belongs_to :monitored_device, optional: true
  has_many :discovery_turns, -> { order(turn_index: :asc) }, dependent: :destroy

  VALID_RESOLUTION_STATUSES = %w[
    in_progress
    confirmed_candidate
    saved_best_guess
    pivoted_to_barcode
    pivoted_to_manual
    abandoned_discarded
  ].freeze

  VALID_MODES = %w[photo_wizard barcode_scan manual_agent].freeze

  validates :session_id, presence: true, uniqueness: true
  validates :resolution_status, inclusion: { in: VALID_RESOLUTION_STATUSES }
  validates :initial_mode, inclusion: { in: VALID_MODES }
  validates :final_mode, inclusion: { in: VALID_MODES }

  def extracted_identifiers_list
    parse_json_array(extracted_identifiers_json)
  end

  def extracted_identifiers_list=(arr)
    self.extracted_identifiers_json = Array(arr).map(&:to_s).uniq.to_json
  end

  def user_clue_notes_list
    parse_json_array(user_clue_notes_json)
  end

  def user_clue_notes_list=(arr)
    self.user_clue_notes_json = Array(arr).map(&:to_s).uniq.to_json
  end

  def to_funnel_hash
    {
      sessionId: session_id,
      networkSiteId: network_site_id,
      monitoredDeviceId: monitored_device_id,
      clientPlatform: client_platform,
      deviceId: device_id,
      initialMode: initial_mode,
      finalMode: final_mode,
      resolutionStatus: resolution_status,
      selectedCandidateRank: selected_candidate_rank,
      wasEdited: was_edited,
      turnsCount: turns_count,
      totalPhotosSubmitted: total_photos_submitted,
      totalCluesSubmitted: total_clues_submitted,
      totalLlmTurns: total_llm_turns,
      shortCircuitedTurns: short_circuited_turns,
      totalTokens: total_tokens,
      totalLatencyMs: total_latency_ms,
      inferredVendor: inferred_vendor,
      inferredModel: inferred_model,
      confirmedVendor: confirmed_vendor,
      confirmedModel: confirmed_model,
      topConfidence: top_confidence,
      goldAlignmentStatus: gold_alignment_status,
      matchedFeedSlug: matched_feed_slug,
      extractedIdentifiers: extracted_identifiers_list,
      userClueNotes: user_clue_notes_list,
      needsCatalogReview: needs_catalog_review,
      resolvedAt: resolved_at&.utc&.iso8601(3),
      createdAt: created_at&.utc&.iso8601(3),
      turns: discovery_turns.map(&:to_turn_hash)
    }
  end

  private

  def parse_json_array(raw)
    JSON.parse(raw.presence || "[]")
  rescue JSON::ParserError
    []
  end
end
