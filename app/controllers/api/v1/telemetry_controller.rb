# frozen_string_literal: true

module Api
  module V1
    # Closed-Loop Production Product Telemetry Controller.
    #
    # Captures wide product telemetry events across all 4 Tuesday.sh / SureThingNet loops:
    # 1. discovery.* (multi-turn photo/barcode/clue funnel & terminal resolution)
    # 2. inventory.* (device enrollment, provisional_guess disambiguation, PURL pruning)
    # 3. bulletin.*  (checklist step toggles, mark complete, snooze 24h, ignore, feed mutes)
    # 4. checkup.* & client.* (quarterly physical rhythm & mobile client fallback/health)
    class TelemetryController < ApplicationController
      include Api::V1::SiteScoping
      skip_before_action :verify_authenticity_token, raise: false

      MAX_BATCH_EVENTS = 50

      # POST /api/v1/telemetry/events
      # Supports single-event or O(1) batched event ingestion (`events: [...]`).
      def create
        raw_events = if params[:events].is_a?(Array)
                       params[:events].first(MAX_BATCH_EVENTS)
                     else
                       [params]
                     end

        site = current_network_site(auto_create: false)
        default_platform = (request.headers["X-Tuesday-Client-Platform"].presence || params[:client_platform].presence || "unknown").to_s.downcase
        default_device_id = (request.headers["X-Tuesday-Device-ID"].presence || params[:device_id].presence || "anonymous").to_s
        default_flavor = (request.headers["X-Tuesday-App-Flavor"].presence || params[:app_flavor].presence || "tuesday").to_s.downcase

        created_events = []
        raw_events.each do |ev_param|
          h = ev_param.respond_to?(:to_unsafe_h) ? ev_param.to_unsafe_h : ev_param.to_h
          event_name = (h["event_name"] || h["eventName"]).to_s.strip
          next if event_name.empty?

          domain_prefix = event_name.split(".").first.to_s.downcase
          domain = (h["event_domain"] || h["eventDomain"]).to_s.strip.downcase
          domain = ProductTelemetryEvent::VALID_DOMAINS.include?(domain) ? domain : (ProductTelemetryEvent::VALID_DOMAINS.include?(domain_prefix) ? domain_prefix : "client")

          props = h["properties"].is_a?(Hash) ? h["properties"] : {}
          ev = ProductTelemetryEvent.create!(
            event_uuid: (h["event_uuid"] || h["eventUuid"]).presence || SecureRandom.uuid,
            event_name: event_name,
            event_domain: domain,
            network_site_id: site&.id,
            client_platform: (h["client_platform"] || h["clientPlatform"] || default_platform).to_s.downcase,
            app_flavor: (h["app_flavor"] || h["appFlavor"] || default_flavor).to_s.downcase,
            device_id: (h["device_id"] || h["deviceId"] || default_device_id).to_s,
            session_id: (h["session_id"] || h["sessionId"]).presence,
            target_entity_type: (h["target_entity_type"] || h["targetEntityType"]).presence,
            target_entity_id: (h["target_entity_id"] || h["targetEntityId"]).presence,
            latency_ms: (h["latency_ms"] || h["latencyMs"])&.to_i,
            llm_turns: (h["llm_turns"] || h["llmTurns"] || 0).to_i,
            total_tokens: (h["total_tokens"] || h["totalTokens"] || 0).to_i,
            properties: props
          )
          Telemetry::HostedAiLogger.log_product_event(ev.to_telemetry_hash)
          created_events << ev.to_telemetry_hash
        end

        render json: {
          status: "recorded",
          recordedCount: created_events.size,
          events: created_events
        }, status: :created
      end

      # GET /api/v1/telemetry/summary
      # Returns closed-loop production funnel & product health analytics.
      def summary
        sessions = DiscoverySession.all
        turns = DiscoveryTurn.all
        events = ProductTelemetryEvent.all

        by_status = sessions.group(:resolution_status).count
        resolved_sessions = sessions.where.not(resolution_status: "in_progress")
        confirmed_sessions = sessions.where(resolution_status: "confirmed_candidate")

        single_turn_confirmed = confirmed_sessions.where("turns_count <= 1").count
        multi_turn_rescued = confirmed_sessions.where("turns_count > 1").count
        top1_unmodified = confirmed_sessions.where(selected_candidate_rank: 0, was_edited: false).count

        catalog_review_queue = sessions
                               .where(needs_catalog_review: true)
                               .order(updated_at: :desc)
                               .limit(15)
                               .map do |s|
          {
            sessionId: s.session_id,
            resolutionStatus: s.resolution_status,
            inferredVendor: s.inferred_vendor,
            inferredModel: s.inferred_model,
            confirmedVendor: s.confirmed_vendor,
            confirmedModel: s.confirmed_model,
            goldAlignmentStatus: s.gold_alignment_status,
            extractedIdentifiers: s.extracted_identifiers_list,
            userClueNotes: s.user_clue_notes_list,
            turnsCount: s.turns_count
          }
        end

        render json: {
          status: "ok",
          generatedAt: Time.now.utc.iso8601,
          discoveryFunnel: {
            totalSessions: sessions.count,
            resolvedSessions: resolved_sessions.count,
            byResolutionStatus: by_status,
            turn1ConfirmedCount: single_turn_confirmed,
            multiTurnClueRescuedCount: multi_turn_rescued,
            top1UnmodifiedHitCount: top1_unmodified,
            totalTurns: turns.count,
            byRoutingTier: turns.group(:routing_tier).count,
            byShortCircuitSource: turns.where.not(short_circuit_source: nil).group(:short_circuit_source).count,
            totalLlmTurns: sessions.sum(:total_llm_turns),
            shortCircuitedTurns: sessions.sum(:short_circuited_turns),
            totalTokens: sessions.sum(:total_tokens)
          },
          catalogExpansionQueue: catalog_review_queue,
          productEventsByDomain: events.group(:event_domain).count,
          productEventsByName: events.group(:event_name).count
        }
      end
    end
  end
end
