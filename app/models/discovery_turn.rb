# frozen_string_literal: true

class DiscoveryTurn < ApplicationRecord
  belongs_to :discovery_session

  VALID_ROUTING_TIERS = %w[
    tier1_short_circuit
    tier2_elastix_vision
    tier2_gemini_failover
    tier3_heuristic
  ].freeze

  validates :session_id, presence: true
  validates :turn_index, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :routing_tier, inclusion: { in: VALID_ROUTING_TIERS }

  def extracted_identifiers_object
    parse_json_object(extracted_identifiers_json)
  end

  def extracted_identifiers_object=(hash)
    self.extracted_identifiers_json = (hash || {}).to_json
  end

  def user_clue_notes_list
    parse_json_array(user_clue_notes_json)
  end

  def user_clue_notes_list=(arr)
    self.user_clue_notes_json = Array(arr).map(&:to_s).to_json
  end

  def previous_guess_object
    parse_json_object(previous_guess_json)
  end

  def previous_guess_object=(hash)
    self.previous_guess_json = (hash || {}).to_json
  end

  def candidates_list
    parse_json_array(candidates_json)
  end

  def candidates_list=(arr)
    self.candidates_json = Array(arr).to_json
  end

  def to_turn_hash
    {
      turnIndex: turn_index,
      imageCount: image_count,
      imageKbTotal: image_kb_total,
      routingTier: routing_tier,
      shortCircuitSource: short_circuit_source,
      provider: provider,
      model: model,
      shortCircuited: short_circuited,
      fallbackUsed: fallback_used,
      latencyMs: latency_ms,
      inputTokens: input_tokens,
      outputTokens: output_tokens,
      cacheReadTokens: cache_read_tokens,
      topVendor: top_vendor,
      topModel: top_model,
      topConfidence: top_confidence,
      discoveryStatus: discovery_status,
      goldAlignmentStatus: gold_alignment_status,
      candidateCount: candidate_count,
      extractedIdentifiers: extracted_identifiers_object,
      userClueNotes: user_clue_notes_list,
      previousGuess: previous_guess_object,
      candidates: candidates_list,
      nextNarrowingQuestion: next_narrowing_question,
      createdAt: created_at&.utc&.iso8601(3)
    }
  end

  private

  def parse_json_array(raw)
    JSON.parse(raw.presence || "[]")
  rescue JSON::ParserError
    []
  end

  def parse_json_object(raw)
    JSON.parse(raw.presence || "{}")
  rescue JSON::ParserError
    {}
  end
end
