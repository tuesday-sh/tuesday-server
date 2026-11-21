# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Telemetry
  # Sends lightweight Discord webhook alerts on key product activation milestones
  # (e.g., first-ever telemetry event from a new external mobile device).
  class DiscordNotifier
    IGNORED_DEVICE_PREFIXES = %w[anonymous test- android-default ios-default].freeze

    class << self
      def notify_first_activation!(event)
        webhook_url = ENV["DISCORD_TELEMETRY_WEBHOOK_URL"].presence
        return :unconfigured if webhook_url.blank?
        return :ignored if ignored_device?(event.device_id)

        payload = build_activation_payload(event)
        post_webhook(webhook_url, payload)
      rescue StandardError => e
        Rails.logger.warn("[Telemetry::DiscordNotifier] Webhook failed: #{e.message}")
        :failed
      end

      def ignored_device?(device_id)
        cid = device_id.to_s.strip.downcase
        return true if cid.blank?

        IGNORED_DEVICE_PREFIXES.any? { |prefix| cid.start_with?(prefix) }
      end

      def build_activation_payload(event)
        {
          username: "Tuesday Activation Bot",
          embeds: [
            {
              title: "New User Activation",
              color: 15_038_489, # #E57819 Tuesday orange
              fields: [
                { name: "Platform", value: event.client_platform.to_s, inline: true },
                { name: "Flavor", value: event.app_flavor.to_s, inline: true },
                { name: "First Event", value: event.event_name.to_s, inline: true },
                { name: "Device ID", value: "`#{event.device_id}`", inline: false }
              ],
              timestamp: (event.created_at || Time.current).utc.iso8601
            }
          ]
        }
      end

      private

      def post_webhook(webhook_url, payload)
        uri = URI(webhook_url)
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(payload)

        resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 5) { |h| h.request(req) }
        resp.is_a?(Net::HTTPSuccess) ? :sent : :failed
      end
    end
  end
end
