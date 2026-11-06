# frozen_string_literal: true

require "json"

class CuratedBulletin < ApplicationRecord
  validates :external_id, presence: true, uniqueness: true
  validates :canonical_feed_slug, presence: true
  validates :bulletin_type, presence: true
  validates :purl_base, presence: true
  validates :pro_title, presence: true
  validates :stn_title, presence: true

  def remediation_steps_list
    JSON.parse(remediation_steps.presence || "[]")
  rescue JSON::ParserError
    []
  end

  def remediation_steps_list=(arr)
    self.remediation_steps = JSON.generate(Array(arr))
  end
end
