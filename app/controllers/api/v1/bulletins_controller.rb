# frozen_string_literal: true

module Api
  module V1
    class BulletinsController < ApplicationController
      skip_before_action :verify_authenticity_token, raise: false

      # GET /api/v1/bulletins
      # Assembles user Bulletins strictly from internal Gold Data Lake snapshots (zero live 3rd-party HTTP calls).
      def index
        app_flavor = params[:flavor].presence || "tuesday"
        muted_slugs = params[:muted_feeds].present? ? params[:muted_feeds].to_s.split(",") : ["lg-esphome-iot"]

        payload = Bulletins::GoldSnapshotLoader.assemble_bulletins_from_gold(
          app_flavor: app_flavor,
          muted_feed_slugs: muted_slugs
        )

        render json: payload
      end
    end
  end
end
