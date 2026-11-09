# frozen_string_literal: true

module Api
  module V1
    class InventoryController < ApplicationController
      include Api::V1::SiteScoping
      skip_before_action :verify_authenticity_token, raise: false

      # GET /api/v1/inventory
      # Returns the 128-LED At-a-Glance Status Matrix (Z0 -> Z4) and Action-First Device List.
      def index
        include_ok = ActiveModel::Type::Boolean.new.cast(params[:include_ok]) || false
        zone_filter = params[:zone].presence || "all"

        site = current_network_site(auto_create: params[:seed_demo].present?)
        if params[:seed_demo].to_s == "forest" && site
          seed_forest_demo_devices!(site)
        end

        tracked_devices = if site && (site.monitored_devices.any? || params[:seed_demo].to_s == "empty")
                            site.monitored_devices.map(&:to_gold_hash)
                          else
                            nil # Falls back to canonical 12-device GoldSnapshotLoader fixture
                          end

        payload = Bulletins::GoldSnapshotLoader.assemble_inventory(
          include_ok: include_ok,
          zone_filter: zone_filter,
          tracked_devices: tracked_devices
        )

        payload[:site] = serialize_site(site) if site
        render json: payload
      end

      # POST /api/v1/inventory
      # Enrolls a new MonitoredDevice into the caller's NetworkSite (128-port M1 limit).
      def create
        site = current_network_site(auto_create: true)
        next_port = params[:port_index].present? ? params[:port_index].to_i : site.next_available_port_index

        if next_port.nil? || next_port > NetworkSite::MAX_PORTS_M1
          return render json: {
            error: "Site port capacity reached (maximum #{NetworkSite::MAX_PORTS_M1} nodes in M1)"
          }, status: :unprocessable_entity
        end

        ver = params[:version].presence || "1.0.0"
        resolved_gold = Discovery::HardwareVisionService.resolve_gold_device_identity(
          vendor: params[:vendor].to_s,
          model: (params[:model_number].presence || params[:short_label]).to_s,
          version: ver
        )
        raw_purls = Array(params[:purls]).map(&:to_s).reject { |p| p.start_with?("pkg:generic/enrolled/") }
        effective_purls = raw_purls.presence || resolved_gold[:purls]
        effective_cat = if params[:category_code].present? && params[:category_code] != "C6" && params[:category_code] != "C8"
                          params[:category_code]
                        else
                          resolved_gold[:category_code].presence || params[:category_code].presence || "C8"
                        end

        device = site.monitored_devices.build(
          external_uuid: params[:id].presence || SecureRandom.uuid,
          port_index: next_port,
          category_code: effective_cat,
          trust_zone: params[:trust_zone].presence || "z1_trusted",
          port_state: params[:port_state].presence || "ok",
          confidence_tier: params[:confidence_tier].presence || "confirmed",
          asset_tag: params[:asset_tag],
          short_label: params[:short_label].presence || params[:model_number].presence || params[:name].to_s[0, 14],
          name: params[:name].presence || "#{params[:vendor]} #{params[:model_number]}".strip,
          vendor: params[:vendor],
          model_number: params[:model_number],
          room_location: params[:room_location].presence || "Rack / Room",
          version: ver,
          target_version: params[:target_version],
          lifecycle_tier: params[:lifecycle_tier].presence || "active"
        )
        device.purls_list = effective_purls
        device.candidate_models_list = Array(params[:candidate_models]) if params[:candidate_models].present?
        device.excluded_purl_prefixes_list = Array(params[:excluded_purl_prefixes]) if params[:excluded_purl_prefixes].present?
        device.version_history_list = Array(params[:version_history]) if params[:version_history].present?

        if device.save
          emit_inventory_telemetry(
            event_name: "inventory.device_enrolled",
            site: site,
            device: device,
            properties: {
              confidenceTier: device.confidence_tier,
              categoryCode: device.category_code,
              trustZone: device.trust_zone,
              vendor: device.vendor,
              modelNumber: device.model_number,
              purls: device.purls_list
            }
          )
          render json: {
            status: "created",
            device: device.to_gold_hash,
            site: serialize_site(site.reload)
          }, status: :created
        else
          render json: { errors: device.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/inventory/:id
      # Supports remediation completion (`port_state: "ok"`), model disambiguation (`confidence_tier: "confirmed"`),
      # negative PURL pruning (`excluded_purl_prefixes`), and zone/room reassignment.
      def update
        site = current_network_site(auto_create: true)
        if site.monitored_devices.none?
          seed_forest_demo_devices!(site)
        end

        device = site.monitored_devices.find_by(external_uuid: params[:id]) ||
                 site.monitored_devices.find_by(id: params[:id])

        if device.nil?
          return render json: { error: "Device not found in site inventory" }, status: :not_found
        end

        updatable = {}
        %i[category_code trust_zone port_state confidence_tier asset_tag short_label name vendor model_number room_location version target_version lifecycle_tier].each do |attr|
          updatable[attr] = params[attr] if params.key?(attr) && params[attr].present?
        end

        if ActiveModel::Type::Boolean.new.cast(params[:mark_remediated])
          updatable[:port_state] = "ok"
          updatable[:version] = device.target_version if device.target_version.present?
        end

        if params[:confirmed_candidate_model].present?
          confirmed = params[:confirmed_candidate_model].to_s
          updatable[:model_number] = confirmed
          updatable[:name] = "#{device.vendor || 'Confirmed'} #{confirmed}".strip
          updatable[:confidence_tier] = "confirmed"
          updatable[:port_state] = "ok" if device.port_state == "guessed"
        end

        device.assign_attributes(updatable)
        device.purls_list = Array(params[:purls]) if params.key?(:purls)
        device.candidate_models_list = Array(params[:candidate_models]) if params.key?(:candidate_models)
        if params.key?(:excluded_purl_prefixes)
          device.excluded_purl_prefixes_list = Array(params[:excluded_purl_prefixes])
        elsif params[:add_excluded_purl_prefix].present?
          device.excluded_purl_prefixes_list = device.excluded_purl_prefixes_list + [params[:add_excluded_purl_prefix].to_s]
        end

        if device.save
          if params[:confirmed_candidate_model].present?
            emit_inventory_telemetry(
              event_name: "inventory.disambiguated",
              site: site,
              device: device,
              properties: {
                confirmedModel: device.model_number,
                vendor: device.vendor,
                candidateModels: device.candidate_models_list
              }
            )
          elsif ActiveModel::Type::Boolean.new.cast(params[:mark_remediated])
            emit_inventory_telemetry(
              event_name: "inventory.remediated",
              site: site,
              device: device,
              properties: {
                vendor: device.vendor,
                modelNumber: device.model_number,
                version: device.version
              }
            )
          elsif params.key?(:excluded_purl_prefixes) || params[:add_excluded_purl_prefix].present?
            emit_inventory_telemetry(
              event_name: "inventory.purl_pruned",
              site: site,
              device: device,
              properties: {
                vendor: device.vendor,
                modelNumber: device.model_number,
                excludedPurlPrefixes: device.excluded_purl_prefixes_list
              }
            )
          end
          render json: {
            status: "updated",
            device: device.to_gold_hash,
            site: serialize_site(site.reload)
          }
        else
          render json: { errors: device.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/inventory/:id
      def destroy
        site = current_network_site(auto_create: false)
        return render json: { error: "Site not found" }, status: :not_found if site.nil?

        if params[:id] == "all"
          site.monitored_devices.destroy_all
          site.recalculate_tier!
          return render json: { status: "reset_to_day_zero", site: serialize_site(site.reload) }
        end

        device = site.monitored_devices.find_by(external_uuid: params[:id]) ||
                 site.monitored_devices.find_by(id: params[:id])
        return render json: { error: "Device not found" }, status: :not_found if device.nil?

        device.destroy!
        render json: { status: "deleted", id: params[:id], site: serialize_site(site.reload) }
      end

      # POST /api/v1/inventory/seed_demo
      def seed_demo
        site = current_network_site(auto_create: true)
        mode = params[:mode].presence || "forest"

        if mode == "empty" || mode == "day_zero"
          site.monitored_devices.destroy_all
          site.recalculate_tier!
        else
          seed_forest_demo_devices!(site)
        end

        render json: {
          status: "seeded",
          mode: mode,
          site: serialize_site(site.reload),
          device_count: site.monitored_devices.count
        }
      end

      private

      def emit_inventory_telemetry(event_name:, site:, device:, properties: {})
        return unless defined?(ProductTelemetryEvent) && ProductTelemetryEvent.table_exists?

        ev = ProductTelemetryEvent.create!(
          event_name: event_name,
          event_domain: "inventory",
          network_site_id: site&.id,
          client_platform: (request.headers["X-Tuesday-Client-Platform"].presence || params[:client_platform].presence || "unknown").to_s.downcase,
          device_id: (request.headers["X-Tuesday-Device-ID"].presence || params[:device_id].presence || "anonymous").to_s,
          target_entity_type: "MonitoredDevice",
          target_entity_id: device.external_uuid,
          properties: properties
        )
        Telemetry::HostedAiLogger.log_product_event(ev.to_telemetry_hash)
      rescue StandardError => e
        Rails.logger.warn("[Api::V1::InventoryController] Telemetry emit skipped: #{e.message}")
      end

      def serialize_site(site)
        return nil if site.nil?

        {
          id: site.id,
          owner_key: site.owner_key,
          name: site.name,
          slug: site.slug,
          site_tier: site.site_tier,
          entitlement_tier: site.entitlement_tier,
          muted_feed_slugs: site.muted_feed_slugs_list,
          device_count: site.monitored_devices.count,
          max_ports: NetworkSite::MAX_PORTS_M1
        }
      end
    end
  end
end
