# frozen_string_literal: true

require "test_helper"

module Api
  module V1
    class DatalakeControllerTest < ActionDispatch::IntegrationTest
      test "POST /api/v1/datalake/sync records Cloud Workflow sync and evaluates fleet matches" do
        post "/api/v1/datalake/sync", params: {
          source_pipeline: "tuesday-bulletin-refinement-dag",
          datalake_version: "2.2.0",
          refined_playbook_ids: ["PB-GOOGLE-NVD-CVE-2021-34991", "PB-EXT-CPSC-24-266-ANKER"]
        }, as: :json

        assert_response :success
        body = JSON.parse(response.body)
        assert_equal "synced", body["status"]
        assert_equal "tuesday-bulletin-refinement-dag", body.dig("sync", "sourcePipeline")
        assert_equal "2.2.0", body.dig("sync", "datalakeVersion")
        assert_equal 2, body.dig("sync", "refinedPlaybookIds")&.size
        assert_operator body.dig("sync", "fleetEvaluation", "monitoredDevicesEvaluated").to_i, :>=, 1

        get "/api/v1/datalake/status"
        assert_response :success
        status_body = JSON.parse(response.body)
        assert_equal "ok", status_body["status"]
        assert_equal "tuesday-bulletin-refinement-dag", status_body.dig("lastCloudWorkflowSync", "sourcePipeline")
      end
    end
  end
end
