# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2026_11_06_190000) do
  create_table "api_keys", force: :cascade do |t|
    t.integer "bearer_id", null: false
    t.string "bearer_type", null: false
    t.string "token", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bearer_id", "bearer_type"], name: "index_api_keys_on_bearer_id_and_bearer_type"
    t.index ["token"], name: "index_api_keys_on_token", unique: true
  end

  create_table "monitored_devices", force: :cascade do |t|
    t.integer "network_site_id", null: false
    t.string "external_uuid", null: false
    t.integer "port_index", null: false
    t.string "category_code", default: "C8", null: false
    t.string "trust_zone", default: "z1_trusted", null: false
    t.string "port_state", default: "ok", null: false
    t.string "confidence_tier", default: "confirmed", null: false
    t.string "asset_tag"
    t.string "short_label", null: false
    t.string "name", null: false
    t.string "vendor"
    t.string "model_number"
    t.string "room_location", default: "Rack / Room"
    t.string "version", default: "1.0.0"
    t.string "target_version"
    t.string "lifecycle_tier", default: "active", null: false
    t.text "purls", default: "[]", null: false
    t.text "candidate_models", default: "[]", null: false
    t.text "excluded_purl_prefixes", default: "[]", null: false
    t.text "version_history", default: "[]", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["network_site_id", "external_uuid"], name: "index_monitored_devices_on_network_site_id_and_external_uuid", unique: true
    t.index ["network_site_id", "port_index"], name: "index_monitored_devices_on_network_site_id_and_port_index", unique: true
    t.index ["network_site_id"], name: "index_monitored_devices_on_network_site_id"
  end

  create_table "network_sites", force: :cascade do |t|
    t.integer "user_id"
    t.string "owner_key", null: false
    t.string "name", default: "Skyway Lab", null: false
    t.string "slug", default: "skyway-lab", null: false
    t.string "site_tier", default: "day_zero", null: false
    t.string "entitlement_tier", default: "free", null: false
    t.boolean "is_default", default: true, null: false
    t.text "muted_feed_slugs", default: "[\"lg-esphome-iot\"]", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_key", "slug"], name: "index_network_sites_on_owner_key_and_slug", unique: true
    t.index ["user_id"], name: "index_network_sites_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  add_foreign_key "monitored_devices", "network_sites"
end
