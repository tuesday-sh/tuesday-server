# frozen_string_literal: true

class CreateGoldDatalakeTables < ActiveRecord::Migration[7.2]
  def change
    create_table :canonical_feeds do |t|
      t.string :external_uuid, null: false
      t.string :slug, null: false
      t.string :pro_name, null: false
      t.string :stn_name, null: false
      t.string :feed_category, null: false, default: "advisory"
      t.text :purl_prefixes, null: false, default: "[]"

      t.timestamps
    end
    add_index :canonical_feeds, :slug, unique: true
    add_index :canonical_feeds, :external_uuid, unique: true

    create_table :curated_bulletins do |t|
      t.string :external_id, null: false
      t.string :canonical_feed_slug, null: false
      t.string :bulletin_type, null: false
      t.boolean :is_high_sev, null: false, default: false
      t.string :purl_base, null: false
      t.string :affected_version_range
      t.string :fixed_version
      t.string :pro_title, null: false
      t.text :pro_body, null: false
      t.string :stn_title, null: false
      t.text :stn_body, null: false
      t.text :ai_pro_bullet, null: false
      t.text :ai_stn_bullet, null: false
      t.text :remediation_steps, null: false, default: "[]"
      t.string :published_at, null: false
      t.string :content_hash

      t.timestamps
    end
    add_index :curated_bulletins, :external_id, unique: true
    add_index :curated_bulletins, :canonical_feed_slug
    add_index :curated_bulletins, :purl_base

    create_table :catalog_releases do |t|
      t.string :purl_base, null: false
      t.string :canonical_feed_slug, null: false
      t.string :version, null: false
      t.string :release_channel, null: false, default: "stable"
      t.string :bump_classification, null: false, default: "patch"
      t.string :released_at, null: false
      t.string :eol_date

      t.timestamps
    end
    add_index :catalog_releases, %i[purl_base version], unique: true
    add_index :catalog_releases, :canonical_feed_slug
  end
end
