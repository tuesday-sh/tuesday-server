# frozen_string_literal: true

require "test_helper"

module DataLake
  class GoldSyncJobTest < ActiveSupport::TestCase
    test "perform upserts canonical_feeds, curated_bulletins, and catalog_releases idempotently" do
      CanonicalFeed.delete_all
      CuratedBulletin.delete_all
      CatalogRelease.delete_all

      result = DataLake::GoldSyncJob.perform_now
      assert_equal 23, result[:canonical_feeds_synced]
      assert_equal 26, result[:curated_bulletins_synced]
      assert_equal 46, result[:catalog_releases_synced]

      assert_equal 23, CanonicalFeed.count
      assert_equal 26, CuratedBulletin.count
      assert_equal 46, CatalogRelease.count

      kev = CuratedBulletin.find_by(external_id: "CVE-2026-21099")
      assert_not_nil kev
      assert kev.is_high_sev
      assert_equal "lg-esphome-iot", kev.canonical_feed_slug
      assert CuratedBulletin.exists?(external_id: "CVE-2024-51978-brother-passbroke")

      # Second run is idempotent (updates in-place without duplicating rows)
      DataLake::GoldSyncJob.perform_now
      assert_equal 23, CanonicalFeed.count
      assert_equal 26, CuratedBulletin.count
      assert_equal 46, CatalogRelease.count
    end
  end
end
