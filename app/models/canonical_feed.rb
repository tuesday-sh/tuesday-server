# frozen_string_literal: true

require "json"

class CanonicalFeed < ApplicationRecord
  validates :external_uuid, presence: true, uniqueness: true
  validates :slug, presence: true, uniqueness: true
  validates :pro_name, presence: true
  validates :stn_name, presence: true

  def purl_prefixes_list
    JSON.parse(purl_prefixes.presence || "[]")
  rescue JSON::ParserError
    []
  end

  def purl_prefixes_list=(arr)
    self.purl_prefixes = JSON.generate(Array(arr))
  end
end
