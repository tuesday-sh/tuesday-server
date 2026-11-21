# frozen_string_literal: true

module Api
  module V1
    class VersionController < ApplicationController
      skip_before_action :verify_authenticity_token, raise: false

      # GET /api/v1/version
      def show
        render json: self.class.version_payload
      end

      def self.version_payload
        {
          status: "ok",
          version: defined?(TuesdayServer::Application::VERSION) ? TuesdayServer::Application::VERSION : "0.0.0",
          gitSha: ENV["GIT_SHA"].presence || ENV["COMMIT_SHA"].presence || "local",
          cloudRunRevision: ENV["K_REVISION"].presence || "local",
          railsEnv: Rails.env
        }
      end
    end
  end
end
