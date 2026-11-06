# frozen_string_literal: true

require "json"

module DataLake
  # Solid Queue / ActiveJob worker that synchronizes signed Gold Data Lake JSON
  # snapshots (`canonical_feeds.json`, `curated_bulletins.json`, `catalog_releases.json`)
  # into the local PostgreSQL 16 / SQLite tables for < 5ms zero-outbound-call serving.
  class GoldSyncJob < ApplicationJob
    queue_as :default

    def perform(lake_dir: nil)
      resolved_dir = lake_dir.presence || Bulletins::GoldSnapshotLoader.resolve_lake_dir
      now = Time.current

      feeds_synced = sync_canonical_feeds(resolved_dir, now)
      bulletins_synced = sync_curated_bulletins(resolved_dir, now)
      releases_synced = sync_catalog_releases(resolved_dir, now)

      {
        lake_dir: resolved_dir,
        canonical_feeds_synced: feeds_synced,
        curated_bulletins_synced: bulletins_synced,
        catalog_releases_synced: releases_synced,
        synced_at: now.utc.iso8601
      }
    end

    private

    def sync_canonical_feeds(lake_dir, now)
      path = File.join(lake_dir, "canonical_feeds.json")
      return 0 unless File.exist?(path)

      rows = JSON.parse(File.read(path))
      rows.each do |row|
        record = CanonicalFeed.find_or_initialize_by(slug: row.fetch("slug"))
        record.assign_attributes(
          external_uuid: row.fetch("id"),
          pro_name: row.fetch("pro_name"),
          stn_name: row.fetch("stn_name"),
          feed_category: row.fetch("feed_category", "advisory"),
          purl_prefixes: JSON.generate(Array(row["purl_prefixes"])),
          updated_at: now
        )
        record.save!
      end
      rows.size
    end

    def sync_curated_bulletins(lake_dir, now)
      path = File.join(lake_dir, "curated_bulletins.json")
      return 0 unless File.exist?(path)

      rows = JSON.parse(File.read(path))
      rows.each do |row|
        record = CuratedBulletin.find_or_initialize_by(external_id: row.fetch("external_id"))
        record.assign_attributes(
          canonical_feed_slug: row.fetch("canonical_feed_slug"),
          bulletin_type: row.fetch("bulletin_type"),
          is_high_sev: ActiveModel::Type::Boolean.new.cast(row["is_high_sev"]),
          purl_base: row.fetch("purl_base"),
          affected_version_range: row["affected_version_range"],
          fixed_version: row["fixed_version"],
          pro_title: row.fetch("pro_title"),
          pro_body: row.fetch("pro_body"),
          stn_title: row.fetch("stn_title"),
          stn_body: row.fetch("stn_body"),
          ai_pro_bullet: row.fetch("ai_pro_bullet"),
          ai_stn_bullet: row.fetch("ai_stn_bullet"),
          remediation_steps: JSON.generate(Array(row["remediation_steps"])),
          published_at: row.fetch("published_at"),
          content_hash: row["content_hash"],
          updated_at: now
        )
        record.save!
      end
      rows.size
    end

    def sync_catalog_releases(lake_dir, now)
      path = File.join(lake_dir, "catalog_releases.json")
      return 0 unless File.exist?(path)

      rows = JSON.parse(File.read(path))
      rows.each do |row|
        record = CatalogRelease.find_or_initialize_by(
          purl_base: row.fetch("purl_base"),
          version: row.fetch("version")
        )
        record.assign_attributes(
          canonical_feed_slug: row.fetch("canonical_feed_slug"),
          release_channel: row.fetch("release_channel", "stable"),
          bump_classification: row.fetch("bump_classification", "patch"),
          released_at: row.fetch("released_at"),
          eol_date: row["eol_date"],
          updated_at: now
        )
        record.save!
      end
      rows.size
    end
  end
end
