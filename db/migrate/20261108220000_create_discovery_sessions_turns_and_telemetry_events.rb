# frozen_string_literal: true

class CreateDiscoverySessionsTurnsAndTelemetryEvents < ActiveRecord::Migration[7.2]
  def change
    create_table :discovery_sessions do |t|
      t.string :session_id, null: false
      t.integer :network_site_id
      t.integer :monitored_device_id
      t.string :client_platform, default: "unknown", null: false
      t.string :device_id, default: "anonymous", null: false
      t.string :initial_mode, default: "photo_wizard", null: false
      t.string :final_mode, default: "photo_wizard", null: false
      t.string :resolution_status, default: "in_progress", null: false
      t.integer :selected_candidate_rank
      t.boolean :was_edited, default: false, null: false
      t.integer :turns_count, default: 0, null: false
      t.integer :total_photos_submitted, default: 0, null: false
      t.integer :total_clues_submitted, default: 0, null: false
      t.integer :total_llm_turns, default: 0, null: false
      t.integer :short_circuited_turns, default: 0, null: false
      t.integer :total_tokens, default: 0, null: false
      t.integer :total_latency_ms, default: 0, null: false
      t.string :inferred_vendor
      t.string :inferred_model
      t.string :confirmed_vendor
      t.string :confirmed_model
      t.float :top_confidence
      t.string :gold_alignment_status
      t.string :matched_feed_slug
      t.text :extracted_identifiers_json, default: "[]", null: false
      t.text :user_clue_notes_json, default: "[]", null: false
      t.boolean :needs_catalog_review, default: false, null: false
      t.datetime :resolved_at

      t.timestamps
    end

    add_index :discovery_sessions, :session_id, unique: true
    add_index :discovery_sessions, :network_site_id
    add_index :discovery_sessions, :monitored_device_id
    add_index :discovery_sessions, :resolution_status
    add_index :discovery_sessions, :needs_catalog_review

    create_table :discovery_turns do |t|
      t.integer :discovery_session_id, null: false
      t.string :session_id, null: false
      t.integer :turn_index, null: false
      t.integer :image_count, default: 0, null: false
      t.float :image_kb_total, default: 0.0, null: false
      t.string :routing_tier, default: "tier2_vision", null: false
      t.string :short_circuit_source
      t.string :provider, null: false
      t.string :model, null: false
      t.boolean :short_circuited, default: false, null: false
      t.boolean :fallback_used, default: false, null: false
      t.integer :latency_ms, default: 0, null: false
      t.integer :input_tokens, default: 0, null: false
      t.integer :output_tokens, default: 0, null: false
      t.integer :cache_read_tokens, default: 0, null: false
      t.string :top_vendor
      t.string :top_model
      t.float :top_confidence
      t.string :discovery_status
      t.string :gold_alignment_status
      t.integer :candidate_count, default: 0, null: false
      t.text :extracted_identifiers_json, default: "{}", null: false
      t.text :user_clue_notes_json, default: "[]", null: false
      t.text :previous_guess_json, default: "{}", null: false
      t.text :candidates_json, default: "[]", null: false
      t.text :next_narrowing_question

      t.timestamps
    end

    add_index :discovery_turns, :discovery_session_id
    add_index :discovery_turns, [:session_id, :turn_index]
    add_index :discovery_turns, :routing_tier

    create_table :product_telemetry_events do |t|
      t.string :event_uuid, null: false
      t.string :event_name, null: false
      t.string :event_domain, null: false
      t.integer :network_site_id
      t.string :client_platform, default: "unknown", null: false
      t.string :app_flavor, default: "tuesday", null: false
      t.string :device_id, default: "anonymous", null: false
      t.string :session_id
      t.string :target_entity_type
      t.string :target_entity_id
      t.integer :latency_ms
      t.integer :llm_turns, default: 0, null: false
      t.integer :total_tokens, default: 0, null: false
      t.text :properties_json, default: "{}", null: false
      t.datetime :occurred_at, null: false

      t.timestamps
    end

    add_index :product_telemetry_events, :event_uuid, unique: true
    add_index :product_telemetry_events, :event_name
    add_index :product_telemetry_events, :event_domain
    add_index :product_telemetry_events, :session_id
    add_index :product_telemetry_events, :occurred_at
  end
end
