# frozen_string_literal: true

class NotificationJobRun < ApplicationRecord
  VALID_STATUSES = %w[running succeeded failed].freeze

  validates :job_key, presence: true
  validates :status, inclusion: { in: VALID_STATUSES }
  validates :started_at, presence: true

  scope :recent, -> { order(started_at: :desc) }

  def to_api_hash
    {
      id: id,
      jobKey: job_key,
      triggerSource: trigger_source,
      status: status,
      startedAt: started_at&.utc&.iso8601,
      finishedAt: finished_at&.utc&.iso8601,
      evaluatedSites: evaluated_sites,
      createdCount: created_count,
      dedupedCount: deduped_count,
      wokenSnoozed: woken_snoozed,
      expiredCount: expired_count,
      errorMessage: error_message
    }
  end
end
