# frozen_string_literal: true

class CreateHardwareCatalogItems < ActiveRecord::Migration[7.2]
  def change
    create_table :hardware_catalog_items do |t|
      t.string :canonical_purl, null: false
      t.string :vendor, null: false
      t.string :brand
      t.string :model, null: false
      t.string :display_name
      t.string :category_code, null: false, default: "C8" # C1-C8
      t.string :upc_gtin
      t.string :fcc_id
      t.string :fcc_grantee
      t.string :lifecycle_tier, default: "active"
      t.string :match_tier, default: "EXACT_SKU_AND_UPC"
      t.text :aliases, default: "[]", null: false
      t.text :specs_metadata, default: "{}", null: false

      t.timestamps
    end

    add_index :hardware_catalog_items, :canonical_purl, unique: true
    add_index :hardware_catalog_items, [:vendor, :model]
    add_index :hardware_catalog_items, :upc_gtin
    add_index :hardware_catalog_items, :fcc_id
    add_index :hardware_catalog_items, :category_code
  end
end
