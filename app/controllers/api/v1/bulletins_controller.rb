# frozen_string_literal: true

module Api
  module V1
    class BulletinsController < ApplicationController
      include Api::V1::SiteScoping
      skip_before_action :verify_authenticity_token, raise: false

      # GET /api/v1/bulletins
      # Assembles user Bulletins strictly from internal Gold Data Lake snapshots (zero live 3rd-party HTTP calls).
      def index
        app_flavor = params[:flavor].presence || "tuesday"
        site = current_network_site(auto_create: false)

        muted_slugs = if params[:muted_feeds].present?
                        params[:muted_feeds].to_s.split(",")
                      elsif site
                        site.muted_feed_slugs_list
                      else
                        ["lg-esphome-iot"]
                      end

        tracked_devices = if site && site.monitored_devices.any?
                            site.monitored_devices.map(&:to_gold_hash)
                          else
                            nil
                          end

        helper_profile = if params[:helper_name].present?
                           {
                             name: params[:helper_name].to_s,
                             relationship: params[:helper_relationship].to_s,
                             linked_pro_account: ActiveModel::Type::Boolean.new.cast(params[:linked_pro_account]) || false
                           }
                         end

        payload = Bulletins::GoldSnapshotLoader.assemble_bulletins_from_gold(
          app_flavor: app_flavor,
          muted_feed_slugs: muted_slugs,
          tracked_devices: tracked_devices,
          helper_profile: helper_profile
        )

        render json: payload
      end
    end
  end
end
