# frozen_string_literal: true

class CreateNotificationJobRuns < ActiveRecord::Migration[7.2]
  def change
    create_table :notification_job_runs do |t|
      t.string :job_key, null: false
      t.string :trigger_source, null: false, default: "rake"
      t.string :status, null: false, default: "running"
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.integer :evaluated_sites, null: false, default: 0
      t.integer :created_count, null: false, default: 0
      t.integer :deduped_count, null: false, default: 0
      t.integer :woken_snoozed, null: false, default: 0
      t.integer :expired_count, null: false, default: 0
      t.text :error_message

      t.timestamps
    end

    add_index :notification_job_runs, [:job_key, :started_at], name: "idx_notif_job_runs_key_started"
    add_index :notification_job_runs, :status
  end
end
