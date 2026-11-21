# frozen_string_literal: true

class CreateSiteNotifications < ActiveRecord::Migration[7.2]
  def change
    create_table :site_notifications do |t|
      t.references :network_site, null: false, foreign_key: true
      t.references :monitored_device, null: true, foreign_key: true
      t.string :rule_id, null: false
      t.string :trigger_type, null: false
      t.string :dedup_key, null: false
      t.text :surfaces_json, null: false, default: '["bulletin"]'
      t.string :priority, null: false, default: "normal"
      t.string :status, null: false, default: "active"
      t.string :push_status, null: false, default: "none"
      t.string :title, null: false
      t.text :body, null: false
      t.string :cta_label
      t.string :deep_link_uri
      t.text :payload_json, null: false, default: "{}"
      t.datetime :snoozed_until
      t.datetime :expires_at
      t.datetime :seen_at
      t.datetime :resolved_at

      t.timestamps
    end

    add_index :site_notifications, [:network_site_id, :dedup_key], unique: true, name: "idx_site_notifications_site_dedup"
    add_index :site_notifications, [:network_site_id, :status, :updated_at], name: "idx_site_notifications_site_status_updated"
    add_index :site_notifications, :rule_id
    add_index :site_notifications, :trigger_type
  end
end
