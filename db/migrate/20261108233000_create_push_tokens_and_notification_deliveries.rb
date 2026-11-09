# frozen_string_literal: true

class CreatePushTokensAndNotificationDeliveries < ActiveRecord::Migration[7.2]
  def change
    create_table :device_push_tokens do |t|
      t.references :network_site, null: false, foreign_key: true
      t.string :client_device_id, null: false
      t.string :platform, null: false, default: "android"
      t.string :app_flavor, null: false, default: "tuesday"
      t.string :fcm_token
      t.boolean :critical_enabled, null: false, default: true
      t.boolean :digest_enabled, null: false, default: true
      t.datetime :last_seen_at
      t.timestamps
    end

    add_index :device_push_tokens, [:network_site_id, :client_device_id], unique: true, name: "idx_device_push_tokens_site_client"
    add_index :device_push_tokens, :fcm_token

    create_table :notification_deliveries do |t|
      t.references :network_site, null: false, foreign_key: true
      t.references :monitored_device, null: true, foreign_key: true
      t.string :client_device_id, null: false
      t.string :bulletin_external_id, null: false
      t.string :feed_slug
      t.string :bulletin_type, null: false, default: "advisory"
      t.boolean :is_high_sev, null: false, default: false
      t.boolean :broke_through_mute, null: false, default: false
      t.boolean :matched_by_guess, null: false, default: false
      t.string :delivery_channel, null: false, default: "tuesday_critical_bulletins"
      t.string :delivery_status, null: false, default: "pending" # pending | sent_fcm | delivered_pull | opened | dismissed
      t.string :title, null: false
      t.text :body, null: false
      t.string :deep_link_uri, null: false
      t.string :device_deep_link_uri
      t.text :payload_json
      t.datetime :sent_at
      t.datetime :delivered_at
      t.datetime :opened_at
      t.timestamps
    end

    add_index :notification_deliveries,
              [:network_site_id, :client_device_id, :bulletin_external_id],
              unique: true,
              name: "idx_notif_deliveries_unique_site_client_bulletin"
    add_index :notification_deliveries, [:client_device_id, :delivery_status], name: "idx_notif_deliveries_client_status"
  end
end
