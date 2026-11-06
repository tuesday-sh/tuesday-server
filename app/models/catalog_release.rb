# frozen_string_literal: true

class CatalogRelease < ApplicationRecord
  validates :purl_base, presence: true
  validates :canonical_feed_slug, presence: true
  validates :version, presence: true, uniqueness: { scope: :purl_base }
end
