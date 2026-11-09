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

ActiveRecord::Schema[7.2].define(version: 2026_11_08_233000) do
  create_table "api_keys", force: :cascade do |t|
    t.integer "bearer_id", null: false
    t.string "bearer_type", null: false
    t.string "token", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bearer_id", "bearer_type"], name: "index_api_keys_on_bearer_id_and_bearer_type"
    t.index ["token"], name: "index_api_keys_on_token", unique: true
  end

  create_table "canonical_feeds", force: :cascade do |t|
    t.string "external_uuid", null: false
    t.string "slug", null: false
    t.string "pro_name", null: false
    t.string "stn_name", null: false
    t.string "feed_category", default: "advisory", null: false
    t.text "purl_prefixes", default: "[]", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["external_uuid"], name: "index_canonical_feeds_on_external_uuid", unique: true
    t.index ["slug"], name: "index_canonical_feeds_on_slug", unique: true
  end

  create_table "catalog_releases", force: :cascade do |t|
    t.string "purl_base", null: false
    t.string "canonical_feed_slug", null: false
    t.string "version", null: false
    t.string "release_channel", default: "stable", null: false
    t.string "bump_classification", default: "patch", null: false
    t.string "released_at", null: false
    t.string "eol_date"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["canonical_feed_slug"], name: "index_catalog_releases_on_canonical_feed_slug"
    t.index ["purl_base", "version"], name: "index_catalog_releases_on_purl_base_and_version", unique: true
  end

  create_table "curated_bulletins", force: :cascade do |t|
    t.string "external_id", null: false
    t.string "canonical_feed_slug", null: false
    t.string "bulletin_type", null: false
    t.boolean "is_high_sev", default: false, null: false
    t.string "purl_base", null: false
    t.string "affected_version_range"
    t.string "fixed_version"
    t.string "pro_title", null: false
    t.text "pro_body", null: false
    t.string "stn_title", null: false
    t.text "stn_body", null: false
    t.text "ai_pro_bullet", null: false
    t.text "ai_stn_bullet", null: false
    t.text "remediation_steps", default: "[]", null: false
    t.string "published_at", null: false
    t.string "content_hash"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["canonical_feed_slug"], name: "index_curated_bulletins_on_canonical_feed_slug"
    t.index ["external_id"], name: "index_curated_bulletins_on_external_id", unique: true
    t.index ["purl_base"], name: "index_curated_bulletins_on_purl_base"
  end

  create_table "device_push_tokens", force: :cascade do |t|
    t.integer "network_site_id", null: false
    t.string "client_device_id", null: false
    t.string "platform", default: "android", null: false
    t.string "app_flavor", default: "tuesday", null: false
    t.string "fcm_token"
    t.boolean "critical_enabled", default: true, null: false
    t.boolean "digest_enabled", default: true, null: false
    t.datetime "last_seen_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["fcm_token"], name: "index_device_push_tokens_on_fcm_token"
    t.index ["network_site_id", "client_device_id"], name: "idx_device_push_tokens_site_client", unique: true
    t.index ["network_site_id"], name: "index_device_push_tokens_on_network_site_id"
  end

  create_table "discovery_sessions", force: :cascade do |t|
    t.string "session_id", null: false
    t.integer "network_site_id"
    t.integer "monitored_device_id"
    t.string "client_platform", default: "unknown", null: false
    t.string "device_id", default: "anonymous", null: false
    t.string "initial_mode", default: "photo_wizard", null: false
    t.string "final_mode", default: "photo_wizard", null: false
    t.string "resolution_status", default: "in_progress", null: false
    t.integer "selected_candidate_rank"
    t.boolean "was_edited", default: false, null: false
    t.integer "turns_count", default: 0, null: false
    t.integer "total_photos_submitted", default: 0, null: false
    t.integer "total_clues_submitted", default: 0, null: false
    t.integer "total_llm_turns", default: 0, null: false
    t.integer "short_circuited_turns", default: 0, null: false
    t.integer "total_tokens", default: 0, null: false
    t.integer "total_latency_ms", default: 0, null: false
    t.string "inferred_vendor"
    t.string "inferred_model"
    t.string "confirmed_vendor"
    t.string "confirmed_model"
    t.float "top_confidence"
    t.string "gold_alignment_status"
    t.string "matched_feed_slug"
    t.text "extracted_identifiers_json", default: "[]", null: false
    t.text "user_clue_notes_json", default: "[]", null: false
    t.boolean "needs_catalog_review", default: false, null: false
    t.datetime "resolved_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["monitored_device_id"], name: "index_discovery_sessions_on_monitored_device_id"
    t.index ["needs_catalog_review"], name: "index_discovery_sessions_on_needs_catalog_review"
    t.index ["network_site_id"], name: "index_discovery_sessions_on_network_site_id"
    t.index ["resolution_status"], name: "index_discovery_sessions_on_resolution_status"
    t.index ["session_id"], name: "index_discovery_sessions_on_session_id", unique: true
  end

  create_table "discovery_turns", force: :cascade do |t|
    t.integer "discovery_session_id", null: false
    t.string "session_id", null: false
    t.integer "turn_index", null: false
    t.integer "image_count", default: 0, null: false
    t.float "image_kb_total", default: 0.0, null: false
    t.string "routing_tier", default: "tier2_vision", null: false
    t.string "short_circuit_source"
    t.string "provider", null: false
    t.string "model", null: false
    t.boolean "short_circuited", default: false, null: false
    t.boolean "fallback_used", default: false, null: false
    t.integer "latency_ms", default: 0, null: false
    t.integer "input_tokens", default: 0, null: false
    t.integer "output_tokens", default: 0, null: false
    t.integer "cache_read_tokens", default: 0, null: false
    t.string "top_vendor"
    t.string "top_model"
    t.float "top_confidence"
    t.string "discovery_status"
    t.string "gold_alignment_status"
    t.integer "candidate_count", default: 0, null: false
    t.text "extracted_identifiers_json", default: "{}", null: false
    t.text "user_clue_notes_json", default: "[]", null: false
    t.text "previous_guess_json", default: "{}", null: false
    t.text "candidates_json", default: "[]", null: false
    t.text "next_narrowing_question"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["discovery_session_id"], name: "index_discovery_turns_on_discovery_session_id"
    t.index ["routing_tier"], name: "index_discovery_turns_on_routing_tier"
    t.index ["session_id", "turn_index"], name: "index_discovery_turns_on_session_id_and_turn_index"
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

  create_table "notification_deliveries", force: :cascade do |t|
    t.integer "network_site_id", null: false
    t.integer "monitored_device_id"
    t.string "client_device_id", null: false
    t.string "bulletin_external_id", null: false
    t.string "feed_slug"
    t.string "bulletin_type", default: "advisory", null: false
    t.boolean "is_high_sev", default: false, null: false
    t.boolean "broke_through_mute", default: false, null: false
    t.boolean "matched_by_guess", default: false, null: false
    t.string "delivery_channel", default: "tuesday_critical_bulletins", null: false
    t.string "delivery_status", default: "pending", null: false
    t.string "title", null: false
    t.text "body", null: false
    t.string "deep_link_uri", null: false
    t.string "device_deep_link_uri"
    t.text "payload_json"
    t.datetime "sent_at"
    t.datetime "delivered_at"
    t.datetime "opened_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["client_device_id", "delivery_status"], name: "idx_notif_deliveries_client_status"
    t.index ["monitored_device_id"], name: "index_notification_deliveries_on_monitored_device_id"
    t.index ["network_site_id", "client_device_id", "bulletin_external_id"], name: "idx_notif_deliveries_unique_site_client_bulletin", unique: true
    t.index ["network_site_id"], name: "index_notification_deliveries_on_network_site_id"
  end

  create_table "product_telemetry_events", force: :cascade do |t|
    t.string "event_uuid", null: false
    t.string "event_name", null: false
    t.string "event_domain", null: false
    t.integer "network_site_id"
    t.string "client_platform", default: "unknown", null: false
    t.string "app_flavor", default: "tuesday", null: false
    t.string "device_id", default: "anonymous", null: false
    t.string "session_id"
    t.string "target_entity_type"
    t.string "target_entity_id"
    t.integer "latency_ms"
    t.integer "llm_turns", default: 0, null: false
    t.integer "total_tokens", default: 0, null: false
    t.text "properties_json", default: "{}", null: false
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["event_domain"], name: "index_product_telemetry_events_on_event_domain"
    t.index ["event_name"], name: "index_product_telemetry_events_on_event_name"
    t.index ["event_uuid"], name: "index_product_telemetry_events_on_event_uuid", unique: true
    t.index ["occurred_at"], name: "index_product_telemetry_events_on_occurred_at"
    t.index ["session_id"], name: "index_product_telemetry_events_on_session_id"
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

  add_foreign_key "device_push_tokens", "network_sites"
  add_foreign_key "monitored_devices", "network_sites"
  add_foreign_key "notification_deliveries", "monitored_devices"
  add_foreign_key "notification_deliveries", "network_sites"
end
