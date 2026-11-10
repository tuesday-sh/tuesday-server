# frozen_string_literal: true

module Api
  module V1
    class DatalakeController < ApplicationController
      skip_before_action :verify_authenticity_token, raise: false

      class << self
        attr_accessor :last_sync_metadata
      end

      # GET /api/v1/datalake/status
      # Returns current Gold Data Lake snapshot version, table counts, and last Cloud Workflow sync status.
      def status
        manifest = load_datalake_manifest
        render json: {
          status: "ok",
          datalakeVersion: manifest["datalake_version"] || "2.2.0",
          generatedAt: manifest["generated_at"],
          lakeDir: File.basename(Bulletins::GoldSnapshotLoader.resolve_lake_dir),
          counts: manifest["counts"] || {},
          lastCloudWorkflowSync: self.class.last_sync_metadata
        }
      end

      # POST /api/v1/datalake/sync
      # Webhook receiver invoked by GCP Cloud Workflows (`tuesday-deterministic-ingestion-dag`
      # and `tuesday-bulletin-refinement-dag`) when upstream feeds or refined playbooks update.
      def sync
        source_pipeline = params[:source_pipeline].presence || "manual"
        incoming_version = params[:datalake_version].presence || load_datalake_manifest["datalake_version"] || "2.2.0"
        refined_playbook_ids = Array(params[:refined_playbook_ids]).map(&:to_s)
        synced_at = Time.now.utc.iso8601

        fleet_eval = evaluate_fleet_against_gold_bulletins
        dispatch_summary = Notifications::FleetBulletinDispatcher.dispatch_for_all_sites!

        sync_record = {
          "sourcePipeline" => source_pipeline,
          "datalakeVersion" => incoming_version,
          "distinctPlaybooksWritten" => params[:distinct_playbooks_written]&.to_i,
          "needsRefinementCount" => params[:needs_refinement_count]&.to_i,
          "refinedPlaybookIds" => refined_playbook_ids,
          "fleetEvaluation" => fleet_eval,
          "notificationsQueued" => dispatch_summary[:notifications_queued],
          "syncedAt" => synced_at
        }
        self.class.last_sync_metadata = sync_record

        render json: {
          status: "synced",
          sync: sync_record
        }
      end

      # GET /api/v1/catalog/clue-index
      # Local/origin fallback mirroring the Cloudflare Worker Edge-pinned Gold Clue Index.
      def clue_index
        lake_dir = Bulletins::GoldSnapshotLoader.resolve_lake_dir
        gz_path = File.join(lake_dir, "gold_clue_index.json.gz")
        json_path = File.join(lake_dir, "gold_clue_index.json")
        return render json: { error: "gold_clue_index not compiled" }, status: :not_found unless File.exist?(gz_path)

        etag_val = if File.exist?(json_path)
                     JSON.parse(File.read(json_path))["etag"].to_s
                   else
                     Digest::SHA256.file(gz_path).hexdigest[0, 12]
                   end
        quoted_etag = "\"#{etag_val}\""
        if_none_match = request.headers["If-None-Match"].to_s.strip
        if [quoted_etag, etag_val, "W/#{quoted_etag}"].include?(if_none_match)
          response.set_header("ETag", quoted_etag)
          head :not_modified
          return
        end

        response.set_header("ETag", quoted_etag)
        response.set_header("Cache-Control", "public, max-age=3600, stale-while-revalidate=86400")
        send_data File.binread(gz_path), type: "application/gzip", disposition: "inline"
      end

      private

      def load_datalake_manifest
        lake_dir = Bulletins::GoldSnapshotLoader.resolve_lake_dir
        manifest_path = File.join(lake_dir, "datalake_manifest.json")
        return {} unless File.exist?(manifest_path)

        JSON.parse(File.read(manifest_path))
      rescue StandardError
        {}
      end

      def evaluate_fleet_against_gold_bulletins
        bulletins = Bulletins::GoldSnapshotLoader.load_gold_bulletins
        bulletin_purl_prefixes = bulletins.map { |b| b.purl_base.to_s.downcase }.reject(&:empty?).uniq

        devices = if defined?(::MonitoredDevice) && ::MonitoredDevice.table_exists? && ::MonitoredDevice.exists?
                    ::MonitoredDevice.all.map(&:to_gold_hash)
                  else
                    Bulletins::GoldSnapshotLoader.golden_tracked_devices
                  end

        matched_device_ids = []
        devices.each do |dev|
          dev_purls = Array(dev[:purls] || dev["purls"]).map { |p| p.to_s.downcase.split("@").first.to_s }
          has_match = dev_purls.any? do |dp|
            bulletin_purl_prefixes.any? { |bp| dp == bp || dp.start_with?("#{bp}/") || bp.start_with?("#{dp}/") }
          end
          matched_device_ids << (dev[:id] || dev["id"]) if has_match
        end

        {
          "monitoredDevicesEvaluated" => devices.size,
          "activeGoldBulletinsCount" => bulletins.size,
          "devicesMatchingBulletinsCount" => matched_device_ids.size
        }
      rescue StandardError => e
        {
          "monitoredDevicesEvaluated" => 0,
          "activeGoldBulletinsCount" => 0,
          "devicesMatchingBulletinsCount" => 0,
          "error" => e.message
        }
      end
    end
  end
end
