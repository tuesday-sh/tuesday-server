# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

module Notifications
  # Dispatches canonical SiteNotification records with `push_status == "pending"`
  # to registered Android (FCM HTTP v1) and iOS (APNs token-based JWT) DevicePushTokens.
  # Uses Ruby stdlib only (no extra gems required).
  class PushDispatcher
    FCM_BASE_URL = "https://fcm.googleapis.com/v1/projects"
    APNS_PROD_HOST = "https://api.push.apple.com"
    APNS_SANDBOX_HOST = "https://api.sandbox.push.apple.com"

    class << self
      def dispatch_pending!(limit: 100)
        pending = SiteNotification.includes(:network_site)
                                  .where(push_status: "pending", status: %w[active seen])
                                  .order(created_at: :asc)
                                  .limit(limit)
                                  .to_a

        sent_count = 0
        failed_count = 0
        skipped_count = 0

        # Collapse identical advisories/rules across multiple sites belonging to the same owner
        grouped = pending.group_by do |n|
          owner = n.network_site&.owner_key || "site-#{n.network_site_id}"
          ext_id = n.payload["external_id"].presence || n.rule_id
          "#{owner}:#{n.rule_id}:#{ext_id}"
        end

        grouped.each_value do |group_notifs|
          result = dispatch_group!(group_notifs)
          case result[:outcome]
          when "sent" then sent_count += group_notifs.size
          when "failed" then failed_count += group_notifs.size
          else skipped_count += group_notifs.size
          end
        end

        {
          sentCount: sent_count,
          failedCount: failed_count,
          skippedCount: skipped_count
        }
      end

      def dispatch_group!(notifs)
        primary = notifs.first
        return { outcome: "skipped_no_tokens" } if primary.nil?
        return dispatch_notification!(primary) if notifs.size == 1

        # Deduplicate device tokens across all affected sites so each physical phone gets 1 OS push
        tokens = notifs.flat_map { |n| eligible_tokens_for(n) }.uniq(&:fcm_token)
        return { outcome: "skipped_no_tokens" } if tokens.empty?

        site_names = notifs.filter_map { |n| n.network_site&.name }.uniq
        collapsed_body = "#{primary.body} (Affects #{site_names.size} networks: #{site_names.join(', ')})"
        collapsed_notif = SiteNotification.new(primary.attributes.merge("body" => collapsed_body))

        attempted = 0
        succeeded = 0
        tokens.each do |device_token|
          res = device_token.platform == "ios" ? send_apns(device_token, collapsed_notif) : send_fcm(device_token, collapsed_notif)
          next if res == :unconfigured

          attempted += 1
          succeeded += 1 if res == :sent
        end

        return { outcome: "skipped_unconfigured" } if attempted.zero?

        new_status = succeeded.positive? ? "sent" : "failed"
        SiteNotification.where(id: notifs.map(&:id)).update_all(push_status: new_status, updated_at: Time.current)
        { outcome: new_status, deliveredTargets: succeeded, collapsedCount: notifs.size }
      end

      def dispatch_notification!(notif)
        tokens = eligible_tokens_for(notif)
        if tokens.empty?
          return { outcome: "skipped_no_tokens", notificationId: notif.id }
        end

        attempted = 0
        succeeded = 0

        tokens.each do |device_token|
          res = if device_token.platform == "ios"
                  send_apns(device_token, notif)
                else
                  send_fcm(device_token, notif)
                end

          next if res == :unconfigured

          attempted += 1
          succeeded += 1 if res == :sent
        end

        if attempted.zero?
          return { outcome: "skipped_unconfigured", notificationId: notif.id }
        end

        if succeeded.positive?
          notif.update!(push_status: "sent")
          { outcome: "sent", notificationId: notif.id, deliveredTargets: succeeded }
        else
          notif.update!(push_status: "failed")
          { outcome: "failed", notificationId: notif.id, deliveredTargets: 0 }
        end
      end

      def eligible_tokens_for(notif)
        return [] unless defined?(DevicePushToken) && DevicePushToken.table_exists?

        is_critical = %w[critical high].include?(notif.priority)
        scope = DevicePushToken.where(network_site_id: notif.network_site_id)
                               .where.not(fcm_token: [nil, ""])
        scope = is_critical ? scope.where(critical_enabled: true) : scope.where(digest_enabled: true)
        scope.to_a
      end

      # Builds an ES256 APNs provider JWT using Ruby stdlib OpenSSL.
      def build_apns_jwt(key_id:, team_id:, private_key_pem:, issued_at: Time.current.to_i)
        header = base64url(JSON.generate(alg: "ES256", kid: key_id))
        claims = base64url(JSON.generate(iss: team_id, iat: issued_at))
        signing_input = "#{header}.#{claims}"
        ec_key = OpenSSL::PKey::EC.new(private_key_pem)
        der_sig = ec_key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(signing_input))
        asn1 = OpenSSL::ASN1.decode(der_sig)
        r = asn1.value[0].value.to_s(2).rjust(32, "\x00")[-32, 32]
        s = asn1.value[1].value.to_s(2).rjust(32, "\x00")[-32, 32]
        "#{signing_input}.#{base64url(r + s)}"
      end

      private

      def send_fcm(device_token, notif)
        project_id = ENV["FCM_PROJECT_ID"].presence
        return :unconfigured if project_id.blank?

        access_token = ENV["FCM_ACCESS_TOKEN"].presence || fetch_gcp_metadata_token
        return :unconfigured if access_token.blank?

        uri = URI("#{FCM_BASE_URL}/#{project_id}/messages:send")
        payload = {
          message: {
            token: device_token.fcm_token,
            notification: {
              title: notif.title,
              body: notif.body
            },
            data: {
              notificationId: notif.id.to_s,
              ruleId: notif.rule_id,
              deepLinkUri: notif.deep_link_uri.to_s,
              priority: notif.priority
            }
          }
        }

        req = Net::HTTP::Post.new(uri)
        req["Authorization"] = "Bearer #{access_token}"
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(payload)

        resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) { |h| h.request(req) }
        resp.is_a?(Net::HTTPSuccess) ? :sent : :failed
      rescue StandardError => e
        Rails.logger.warn("[Notifications::PushDispatcher] FCM error: #{e.message}")
        :failed
      end

      def send_apns(device_token, notif)
        key_id = ENV["APNS_KEY_ID"].presence
        team_id = ENV["APNS_TEAM_ID"].presence
        private_key = ENV["APNS_PRIVATE_KEY"].presence
        return :unconfigured if key_id.blank? || team_id.blank? || private_key.blank?

        host = ENV["APNS_USE_SANDBOX"].to_s == "true" ? APNS_SANDBOX_HOST : APNS_PROD_HOST
        uri = URI("#{host}/3/device/#{device_token.fcm_token}")
        jwt = build_apns_jwt(key_id: key_id, team_id: team_id, private_key_pem: private_key)

        payload = {
          aps: {
            alert: {
              title: notif.title,
              body: notif.body
            },
            sound: "default"
          },
          notificationId: notif.id,
          ruleId: notif.rule_id,
          deepLinkUri: notif.deep_link_uri.to_s
        }

        req = Net::HTTP::Post.new(uri)
        req["authorization"] = "bearer #{jwt}"
        req["apns-topic"] = ENV.fetch("APNS_BUNDLE_ID", "sh.tuesday.app")
        req["apns-push-type"] = "alert"
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(payload)

        resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) { |h| h.request(req) }
        resp.is_a?(Net::HTTPSuccess) ? :sent : :failed
      rescue StandardError => e
        Rails.logger.warn("[Notifications::PushDispatcher] APNs error: #{e.message}")
        :failed
      end

      def fetch_gcp_metadata_token
        return nil unless ENV["K_SERVICE"].present? || ENV["CLOUD_RUN_JOB"].present?

        uri = URI("http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token")
        req = Net::HTTP::Get.new(uri)
        req["Metadata-Flavor"] = "Google"
        resp = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 3) { |h| h.request(req) }
        return nil unless resp.is_a?(Net::HTTPSuccess)

        JSON.parse(resp.body)["access_token"]
      rescue StandardError
        nil
      end

      def base64url(bytes)
        Base64.urlsafe_encode64(bytes, padding: false)
      end
    end
  end
end
