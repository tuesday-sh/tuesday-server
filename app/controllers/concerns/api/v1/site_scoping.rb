# frozen_string_literal: true

module Api
  module V1
    module SiteScoping
      extend ActiveSupport::Concern

      private

      def current_owner_key
        bearer_token = request.headers["Authorization"].to_s[/\ABearer\s+(.+)\z/i, 1]&.strip
        expected_pilot_token = ENV.fetch("TUESDAY_PILOT_CLIENT_TOKEN", "tuesday-pilot-v1-public-client-token")

        if bearer_token.present? && bearer_token != expected_pilot_token && defined?(ApiKey) && ApiKey.table_exists?
          api_key = ApiKey.find_by(token: bearer_token)
          return "user-#{api_key.bearer_id}" if api_key
        end

        device_id = (request.headers["X-Tuesday-Device-ID"].presence || params[:device_id].presence).to_s.strip
        return "device-#{device_id}" if device_id.present?

        "default-demo-owner"
      end

      def current_site_slug
        (request.headers["X-Tuesday-Site-Slug"].presence || params[:site_slug].presence || "net-default").to_s.parameterize.presence || "net-default"
      end

      def current_network_site(auto_create: false)
        return nil unless defined?(NetworkSite) && NetworkSite.table_exists?

        owner = current_owner_key
        slug = current_site_slug
        site = NetworkSite.find_by(owner_key: owner, slug: slug) || NetworkSite.find_by(owner_key: owner)

        if site.nil? && auto_create
          site = NetworkSite.create!(
            owner_key: owner,
            name: params[:site_name].presence || "My Network",
            slug: slug,
            site_tier: "day_zero",
            entitlement_tier: "free"
          )
        end

        site
      end

      def seed_forest_demo_devices!(site)
        return site if site.nil?

        ActiveRecord::Base.transaction do
          site.monitored_devices.destroy_all
          Bulletins::GoldSnapshotLoader.golden_tracked_devices.each do |gold|
            site.monitored_devices.create!(
              external_uuid: gold[:id],
              port_index: gold[:port_index],
              category_code: infer_category_code(gold),
              trust_zone: gold[:trust_zone],
              port_state: gold[:port_state],
              confidence_tier: gold[:confidence_tier].to_s,
              asset_tag: gold[:asset_tag],
              short_label: gold[:short_label],
              name: gold[:name],
              vendor: infer_vendor(gold[:name], gold[:purls]),
              model_number: gold[:short_label],
              room_location: gold[:room_location],
              version: gold[:version],
              target_version: gold[:target_version],
              lifecycle_tier: gold[:lifecycle_tier],
              purls_list: gold[:purls],
              candidate_models_list: gold[:candidate_models],
              excluded_purl_prefixes_list: gold[:excluded_purl_prefixes]
            )
          end
          site.recalculate_tier!
        end

        site
      end

      def infer_category_code(gold)
        case gold[:trust_zone]
        when "z0_core"
          gold[:port_index] == 1 ? "C1" : "C2"
        when "z2_lab"
          gold[:short_label].to_s.downcase.include?("unraid") ? "C3" : "C4"
        when "z3_iot"
          gold[:short_label].to_s.downcase.include?("cam") ? "C6" : "C7"
        else
          "C8"
        end
      end

      def infer_vendor(name, purls)
        first_purl = Array(purls).first.to_s
        if first_purl =~ %r{\Apkg:[^/]+/([^/]+)/}
          return Regexp.last_match(1).capitalize
        end
        name.to_s.split.first || "Generic"
      end
    end
  end
end
