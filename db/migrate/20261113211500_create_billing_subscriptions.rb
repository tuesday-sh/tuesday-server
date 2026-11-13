# frozen_string_literal: true

class CreateBillingSubscriptions < ActiveRecord::Migration[7.2]
  def change
    create_table :billing_subscriptions do |t|
      t.references :network_site, null: false, foreign_key: true
      t.string :platform, null: false, default: "android"
      t.string :package_name, null: false, default: "sh.tuesday.app"
      t.string :product_id, null: false
      t.string :purchase_token, null: false
      t.string :external_account_id
      t.string :external_profile_id
      t.string :entitlement_tier, null: false, default: "pro_tier_1"
      t.string :subscription_state, null: false, default: "SUBSCRIPTION_STATE_ACTIVE"
      t.string :verification_source, null: false, default: "sandbox"
      t.boolean :auto_renewing, null: false, default: true
      t.boolean :is_test_purchase, null: false, default: false
      t.datetime :expires_at
      t.datetime :last_verified_at
      t.text :raw_metadata_json, null: false, default: "{}"

      t.timestamps
    end

    add_index :billing_subscriptions, :purchase_token, unique: true
    add_index :billing_subscriptions, [:network_site_id, :subscription_state], name: "idx_billing_subs_site_state"
  end
end
