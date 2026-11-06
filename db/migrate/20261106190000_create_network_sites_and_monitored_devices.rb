# frozen_string_literal: true

class CreateNetworkSitesAndMonitoredDevices < ActiveRecord::Migration[7.2]
  def change
    create_table :network_sites do |t|
      t.integer :user_id
      t.string :owner_key, null: false
      t.string :name, null: false, default: "Skyway Lab"
      t.string :slug, null: false, default: "skyway-lab"
      t.string :site_tier, null: false, default: "day_zero"
      t.string :entitlement_tier, null: false, default: "free"
      t.boolean :is_default, null: false, default: true
      t.text :muted_feed_slugs, null: false, default: '["lg-esphome-iot"]'

      t.timestamps
    end

    add_index :network_sites, :user_id
    add_index :network_sites, [:owner_key, :slug], unique: true

    create_table :monitored_devices do |t|
      t.references :network_site, null: false, foreign_key: true
      t.string :external_uuid, null: false
      t.integer :port_index, null: false
      t.string :category_code, null: false, default: "C8"
      t.string :trust_zone, null: false, default: "z1_trusted"
      t.string :port_state, null: false, default: "ok"
      t.string :confidence_tier, null: false, default: "confirmed"
      t.string :asset_tag
      t.string :short_label, null: false
      t.string :name, null: false
      t.string :vendor
      t.string :model_number
      t.string :room_location, default: "Rack / Room"
      t.string :version, default: "1.0.0"
      t.string :target_version
      t.string :lifecycle_tier, null: false, default: "active"
      t.text :purls, null: false, default: "[]"
      t.text :candidate_models, null: false, default: "[]"
      t.text :excluded_purl_prefixes, null: false, default: "[]"
      t.text :version_history, null: false, default: "[]"

      t.timestamps
    end

    add_index :monitored_devices, [:network_site_id, :port_index], unique: true
    add_index :monitored_devices, [:network_site_id, :external_uuid], unique: true
  end
end
