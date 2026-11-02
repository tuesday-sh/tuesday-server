# frozen_string_literal: true

module Api
  module V1
    class InventoryController < ApplicationController
      skip_before_action :verify_authenticity_token, raise: false

      # GET /api/v1/inventory
      # Returns the 128-LED At-a-Glance Status Matrix (Z0 -> Z4) and Action-First Device List.
      def index
        include_ok = ActiveModel::Type::Boolean.new.cast(params[:include_ok]) || false
        zone_filter = params[:zone].presence || "all"

        payload = Bulletins::GoldSnapshotLoader.assemble_inventory(
          include_ok: include_ok,
          zone_filter: zone_filter
        )

        render json: payload
      end
    end
  end
end
