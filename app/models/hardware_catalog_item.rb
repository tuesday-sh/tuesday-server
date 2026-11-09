# frozen_string_literal: true

class HardwareCatalogItem < ApplicationRecord
  VALID_CATEGORIES = %w[C1 C2 C3 C4 C5 C6 C7 C8].freeze

  validates :canonical_purl, presence: true, uniqueness: true
  validates :vendor, presence: true
  validates :model, presence: true
  validates :category_code, inclusion: { in: VALID_CATEGORIES }

  scope :by_category, ->(code) { where(category_code: code) }
  scope :by_upc, ->(upc) { where(upc_gtin: upc) }
  scope :by_vendor_and_model, ->(v, m) { where("LOWER(vendor) = ? AND LOWER(model) = ?", v.to_s.downcase, m.to_s.downcase) }

  def self.lookup_identifier(candidate_str)
    return nil if candidate_str.blank?
    clean = candidate_str.to_s.strip

    # 1. Exact UPC match
    if clean.match?(/\A\d{8,14}\z/)
      item = find_by(upc_gtin: clean)
      return item if item
    end

    # 2. FCC ID match
    if clean.match?(/\A[A-Z0-9]{3,5}-[A-Z0-9]+\z/i)
      item = find_by("LOWER(fcc_id) = ?", clean.downcase)
      return item if item
    end

    # 3. Model exact match
    find_by("LOWER(model) = ?", clean.downcase)
  end
end
