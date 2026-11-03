# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "openssl"
require "time"
require "fileutils"

module Telemetry
  # Emits Hosted Production AI Telemetry to:
  # 1. AWS CloudWatch Logs (/tuesday/codeburn -> stream hosted-ai-v1) using flat camelCase
  #    fields identical to our CloudWatch Omni schema (costUSD, totalTokens, inputTokens, etc.).
  # 2. Tuesday Bronze Datalake JSONL ledger (tuesday-datalake/bronze/vision_inferences.jsonl).
  #
  # PRIVACY COMPLIANCE INVARIANT:
  # Never accepts or logs camera image bytes or Base64 image strings.
  class HostedAiLogger
    CLOUDWATCH_REGION = ENV.fetch("TUESDAY_CW_REGION", "us-west-2")
    CLOUDWATCH_LOG_GROUP = ENV.fetch("TUESDAY_CW_LOG_GROUP", "/tuesday/codeburn")
    CLOUDWATCH_LOG_STREAM = ENV.fetch("TUESDAY_CW_HOSTED_STREAM", "hosted-ai-v1")

    DEFAULT_BRONZE_DIR = File.expand_path("../../../../../tuesday-datalake/bronze", __FILE__)
    WORKSPACE_AWS_CREDS = File.expand_path("../../../../../.agents/configs/aws-agy/credentials", __FILE__)

    # Per-1M token pricing in USD
    MODEL_PRICING_PER_1M = {
      "qwen3.8-27b" => { input: 0.30, cached_input: 0.05, output: 1.20 },
      "gemini-3.8-flash" => { input: 0.15, cached_input: 0.0375, output: 0.60 },
      "gemini-2.5-flash" => { input: 0.15, cached_input: 0.0375, output: 0.60 },
      "gold-short-circuit" => { input: 0.0, cached_input: 0.0, output: 0.0 },
      "heuristic-fallback" => { input: 0.0, cached_input: 0.0, output: 0.0 }
    }.freeze

    class << self
      def calculate_cost_usd(model:, input_tokens:, output_tokens:, cache_read_tokens: 0)
        rates = MODEL_PRICING_PER_1M[model.to_s] || { input: 0.25, cached_input: 0.05, output: 1.00 }
        uncached_input = [input_tokens.to_i - cache_read_tokens.to_i, 0].max
        cost = (uncached_input * rates[:input] / 1_000_000.0) +
               (cache_read_tokens.to_i * rates[:cached_input] / 1_000_000.0) +
               (output_tokens.to_i * rates[:output] / 1_000_000.0)
        cost.round(6)
      end

      def log_ai_call(
        feature:,
        provider:,
        model:,
        status: "success",
        client_platform: "unknown",
        device_id: "anonymous",
        session_id: nil,
        turn_index: 1,
        fallback_used: false,
        short_circuited: false,
        latency_ms: 0,
        input_tokens: 0,
        output_tokens: 0,
        cache_read_tokens: 0,
        cache_write_tokens: 0,
        confidence: nil,
        inferred_vendor: nil,
        inferred_model: nil,
        extracted_identifiers: [],
        async: !Rails.env.test?
      )
        total_tokens = input_tokens.to_i + output_tokens.to_i + cache_read_tokens.to_i + cache_write_tokens.to_i
        cost_usd = calculate_cost_usd(
          model: model,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cache_read_tokens: cache_read_tokens
        )

        now = Time.now.utc
        record = {
          "event" => "hosted_ai_call",
          "timestamp" => now.iso8601(3),
          "date" => now.strftime("%Y-%m-%d"),
          "venture" => "tuesday-sh",
          "source" => "tuesday-server",
          "environment" => Rails.env,
          "feature" => feature.to_s,
          "clientPlatform" => client_platform.to_s,
          "deviceId" => device_id.to_s,
          "sessionId" => session_id.to_s,
          "turnIndex" => turn_index.to_i,
          "provider" => provider.to_s,
          "model" => model.to_s,
          "status" => status.to_s,
          "fallbackUsed" => !!fallback_used,
          "shortCircuited" => !!short_circuited,
          "latencyMs" => latency_ms.to_i,
          "calls" => 1,
          "inputTokens" => input_tokens.to_i,
          "outputTokens" => output_tokens.to_i,
          "cacheReadTokens" => cache_read_tokens.to_i,
          "cacheWriteTokens" => cache_write_tokens.to_i,
          "totalTokens" => total_tokens,
          "costUSD" => cost_usd,
          "confidence" => confidence&.to_f,
          "inferredVendor" => inferred_vendor,
          "inferredModel" => inferred_model,
          "extractedIdentifiers" => Array(extracted_identifiers).map(&:to_s).first(20),
          "imageRetention" => "none_ephemeral_ram_only"
        }

        dispatch_record(record, async: async)
        record
      end

      def log_confirmation(
        session_id:,
        client_platform: "unknown",
        device_id: "anonymous",
        inferred_vendor: nil,
        inferred_model: nil,
        confirmed_vendor:,
        confirmed_model:,
        was_edited: false,
        extracted_identifiers: [],
        async: !Rails.env.test?
      )
        now = Time.now.utc
        record = {
          "event" => "hosted_ai_confirm",
          "timestamp" => now.iso8601(3),
          "date" => now.strftime("%Y-%m-%d"),
          "venture" => "tuesday-sh",
          "source" => "tuesday-server",
          "environment" => Rails.env,
          "feature" => "hardware_discovery",
          "clientPlatform" => client_platform.to_s,
          "deviceId" => device_id.to_s,
          "sessionId" => session_id.to_s,
          "inferredVendor" => inferred_vendor,
          "inferredModel" => inferred_model,
          "confirmedVendor" => confirmed_vendor.to_s,
          "confirmedModel" => confirmed_model.to_s,
          "wasEdited" => !!was_edited,
          "accuracyScore" => was_edited ? 0.0 : 1.0,
          "extractedIdentifiers" => Array(extracted_identifiers).map(&:to_s).first(20),
          "imageRetention" => "none_ephemeral_ram_only"
        }

        dispatch_record(record, async: async)
        record
      end

      def dispatch_record(record, async: true)
        if async
          Thread.new do
            write_bronze_jsonl(record)
            ship_to_cloudwatch(record)
          rescue StandardError => e
            Rails.logger.warn("[Telemetry::HostedAiLogger] Async telemetry warning: #{e.message}")
          end
        else
          write_bronze_jsonl(record)
          ship_to_cloudwatch(record)
        end
      end

      def write_bronze_jsonl(record, bronze_dir: ENV.fetch("BRONZE_LAKE_DIR", DEFAULT_BRONZE_DIR))
        FileUtils.mkdir_p(bronze_dir)
        file_path = File.join(bronze_dir, "vision_inferences.jsonl")
        File.open(file_path, "a") do |f|
          f.puts(JSON.generate(record))
        end
      rescue StandardError => e
        Rails.logger.warn("[Telemetry::HostedAiLogger] Bronze write skipped: #{e.message}")
      end

      def ship_to_cloudwatch(record)
        return false if Rails.env.test? && ENV["ENABLE_CW_IN_TEST"] != "true"

        creds = resolve_aws_credentials
        return false unless creds[:access_key_id] && creds[:secret_access_key]

        ensure_log_stream(creds)

        payload = JSON.generate({
          "logGroupName" => CLOUDWATCH_LOG_GROUP,
          "logStreamName" => CLOUDWATCH_LOG_STREAM,
          "logEvents" => [
            {
              "timestamp" => (Time.now.to_f * 1000).to_i,
              "message" => JSON.generate(record)
            }
          ]
        })

        res = signed_cw_request("Logs_20140328.PutLogEvents", payload, creds)
        res.is_a?(Net::HTTPSuccess)
      rescue StandardError => e
        Rails.logger.warn("[Telemetry::HostedAiLogger] CloudWatch ship failed: #{e.message}")
        false
      end

      def resolve_aws_credentials
        access_key = ENV["AWS_ACCESS_KEY_ID"]
        secret_key = ENV["AWS_SECRET_ACCESS_KEY"]
        session_token = ENV["AWS_SESSION_TOKEN"]

        if (access_key.nil? || access_key.empty?) && File.exist?(WORKSPACE_AWS_CREDS)
          content = File.read(WORKSPACE_AWS_CREDS)
          access_key = content[/aws_access_key_id\s*=\s*(\S+)/, 1]
          secret_key = content[/aws_secret_access_key\s*=\s*(\S+)/, 1]
        end

        { access_key_id: access_key, secret_access_key: secret_key, session_token: session_token }
      end

      private

      def ensure_log_stream(creds)
        return if @stream_ensured

        payload = JSON.generate({
          "logGroupName" => CLOUDWATCH_LOG_GROUP,
          "logStreamName" => CLOUDWATCH_LOG_STREAM
        })
        signed_cw_request("Logs_20140328.CreateLogStream", payload, creds)
        @stream_ensured = true
      rescue StandardError
        @stream_ensured = true
      end

      def signed_cw_request(amz_target, body, creds)
        host = "logs.#{CLOUDWATCH_REGION}.amazonaws.com"
        uri = URI("https://#{host}/")
        now = Time.now.utc
        amz_date = now.strftime("%Y%m%dT%H%M%SZ")
        datestamp = now.strftime("%Y%m%d")
        service = "logs"
        content_type = "application/x-amz-json-1.1"
        payload_hash = OpenSSL::Digest::SHA256.hexdigest(body)

        canonical_headers = "content-type:#{content_type}\nhost:#{host}\nx-amz-date:#{amz_date}\nx-amz-target:#{amz_target}\n"
        signed_headers = "content-type;host;x-amz-date;x-amz-target"
        if creds[:session_token] && !creds[:session_token].empty?
          canonical_headers += "x-amz-security-token:#{creds[:session_token]}\n"
          signed_headers += ";x-amz-security-token"
        end

        canonical_request = [
          "POST",
          "/",
          "",
          canonical_headers,
          signed_headers,
          payload_hash
        ].join("\n")

        credential_scope = "#{datestamp}/#{CLOUDWATCH_REGION}/#{service}/aws4_request"
        string_to_sign = [
          "AWS4-HMAC-SHA256",
          amz_date,
          credential_scope,
          OpenSSL::Digest::SHA256.hexdigest(canonical_request)
        ].join("\n")

        k_date = hmac_sha256("AWS4#{creds[:secret_access_key]}", datestamp)
        k_region = hmac_sha256(k_date, CLOUDWATCH_REGION)
        k_service = hmac_sha256(k_region, service)
        k_signing = hmac_sha256(k_service, "aws4_request")
        signature = OpenSSL::HMAC.hexdigest("SHA256", k_signing, string_to_sign)

        auth_header = "AWS4-HMAC-SHA256 Credential=#{creds[:access_key_id]}/#{credential_scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"

        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = content_type
        req["Host"] = host
        req["X-Amz-Date"] = amz_date
        req["X-Amz-Target"] = amz_target
        req["X-Amz-Security-Token"] = creds[:session_token] if creds[:session_token] && !creds[:session_token].empty?
        req["Authorization"] = auth_header
        req.body = body

        Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 4, read_timeout: 6) do |http|
          http.request(req)
        end
      end

      def hmac_sha256(key, data)
        OpenSSL::HMAC.digest("SHA256", key, data)
      end
    end
  end
end
