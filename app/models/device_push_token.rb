# frozen_string_literal: true

class DevicePushToken < ApplicationRecord
  belongs_to :network_site

  validates :client_device_id, presence: true
  validates :platform, inclusion: { in: %w[android ios web] }
  validates :app_flavor, inclusion: { in: %w[tuesday surethingnet surething] }
end
