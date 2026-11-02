# frozen_string_literal: true

require "set"

module Bulletins
  # Assembles a user's Bulletins view strictly from pre-curated Gold Data Lake records.
  #
  # Core Invariants:
  # 1. Zero Live 3rd-Party Requests: Never performs external HTTP calls or synchronous LLM inference.
  # 2. Matched Device Feeds Only: Filters the 140+ backend canonical feeds down to only those
  #    matching at least one tracked device's PURL in the user's inventory.
  # 3. Mute != Remove: Muting a feed excludes its items from the top-level AI Summary and hides
  #    routine release notes (is_high_sev: false).
  # 4. High-Severity Override: High-severity bulletins (is_high_sev: true — CPSC Recalls, CISA KEVs,
  #    0-Day CVEs, Vendor EOL) from muted feeds still break through into the Inbox with
  #    broke_through_mute: true.
  # 5. Best-Guess (provisional_guess) Device Rules:
  #    - Tier C (:opaque_unknown) devices attach 0 feeds.
  #    - Tier B (:provisional_guess) devices attach at most 1 Umbrella Feed, default to
  #      High-Sev Guardrail Mode (excluded from AI Summary + routine releases suppressed,
  #      high-sev family alerts break through with matched_by_guess: true + candidate_models),
  #      and respect negative pruning via excluded_purl_prefixes.
  class InboxAssembler
    CanonicalFeedStruct = Struct.new(:id, :slug, :pro_name, :stn_name, :purl_prefixes, keyword_init: true) do
      def matches_purl?(purl)
        return false if purl.nil? || purl.empty?

        clean_purl = purl.split("@").first.sub(/\/\*$/, "")
        Array(purl_prefixes).any? do |prefix|
          clean_prefix = prefix.sub(/\/\*$/, "")
          clean_purl.start_with?(clean_prefix) || clean_prefix.start_with?(clean_purl)
        end
      end
    end

    TrackedDeviceStruct = Struct.new(
      :id,
      :port_index,
      :short_label,
      :purls,
      :confidence_tier,         # :confirmed (default) | :provisional_guess | :opaque_unknown
      :candidate_models,        # Array of candidate model strings for 1-tap disambiguation
      :excluded_purl_prefixes,  # Negative pruning list ("Not My Model")
      keyword_init: true
    ) do
      def effective_tier
        (confidence_tier || :confirmed).to_sym
      end

      def excludes_purl?(purl_base)
        Array(excluded_purl_prefixes).any? { |ex| purl_base.to_s.start_with?(ex) }
      end
    end

    CuratedBulletinStruct = Struct.new(
      :external_id,
      :canonical_feed_id,
      :bulletin_type,
      :is_high_sev,
      :purl_base,
      :pro_title,
      :pro_body,
      :stn_title,
      :stn_body,
      :ai_pro_bullet,
      :ai_stn_bullet,
      :published_at,
      keyword_init: true
    )

    def self.assemble(
      canonical_feeds:,
      tracked_devices:,
      muted_feed_ids:,
      curated_bulletins:,
      app_flavor: "tuesday"
    )
      is_stn = (app_flavor.to_s == "surethingnet")
      muted_set = Array(muted_feed_ids).to_set

      # Rule 1 & Rule 3: Map each device to its matched feeds, enforcing:
      # - :opaque_unknown devices attach 0 feeds
      # - :provisional_guess devices attach at most 1 Umbrella Feed
      device_feed_links = Hash.new { |h, k| h[k] = [] }

      tracked_devices.each do |dev|
        tier = dev.effective_tier
        next if tier == :opaque_unknown

        matching = canonical_feeds.select do |feed|
          Array(dev.purls).any? do |purl|
            !dev.excludes_purl?(purl) && feed.matches_purl?(purl)
          end
        end

        matching = matching.first(1) if tier == :provisional_guess
        matching.each do |feed|
          device_feed_links[feed.id] << dev
        end
      end

      matched_feeds = canonical_feeds.select { |f| device_feed_links.key?(f.id) }
      matched_feed_ids = matched_feeds.map(&:id).to_set
      feed_by_id = matched_feeds.each_with_object({}) { |f, h| h[f.id] = f }

      # Determine which feeds are confirmed vs provisional_guess-only
      provisional_only_feed_ids = Set.new
      feed_summaries = matched_feeds.map do |feed|
        linked_devs = device_feed_links[feed.id]
        has_confirmed_dev = linked_devs.any? { |d| d.effective_tier == :confirmed }
        match_mode = has_confirmed_dev ? "confirmed" : "provisional_guess"
        provisional_only_feed_ids.add(feed.id) unless has_confirmed_dev

        {
          id: feed.id,
          slug: feed.slug,
          name: is_stn ? feed.stn_name : feed.pro_name,
          match_mode: match_mode,
          matched_ports: linked_devs.map { |d| "##{format('%02d', d.port_index)} #{d.short_label}" },
          candidate_models: linked_devs.flat_map { |d| Array(d.candidate_models) }.uniq,
          muted: muted_set.include?(feed.id)
        }
      end

      # Filter curated bulletins to those matching non-excluded device PURLs on matched feeds
      relevant_bulletins = curated_bulletins.select do |b|
        next false unless matched_feed_ids.include?(b.canonical_feed_id)

        linked_devs = device_feed_links[b.canonical_feed_id]
        linked_devs.any? do |dev|
          !dev.excludes_purl?(b.purl_base) &&
            Array(dev.purls).any? do |dp|
              clean_dp = dp.split("@").first.sub(/\/\*$/, "")
              b.purl_base.start_with?(clean_dp) || clean_dp.start_with?(b.purl_base)
            end
        end
      end

      # Top-Level AI Summary: Strictly excludes BOTH muted feeds AND provisional_guess feeds
      unmuted_confirmed_bulletins = relevant_bulletins.reject do |b|
        muted_set.include?(b.canonical_feed_id) || provisional_only_feed_ids.include?(b.canonical_feed_id)
      end

      muted_high_sev_count = relevant_bulletins.count do |b|
        muted_set.include?(b.canonical_feed_id) && b.is_high_sev
      end

      provisional_high_sev_count = relevant_bulletins.count do |b|
        provisional_only_feed_ids.include?(b.canonical_feed_id) && b.is_high_sev
      end

      ai_bullets = unmuted_confirmed_bulletins.map do |b|
        is_stn ? b.ai_stn_bullet : b.ai_pro_bullet
      end

      # Bulletin Inbox:
      # - Confirmed unmuted feeds: show all items
      # - Muted feeds OR Provisional Guess feeds: ONLY show High-Sev items (is_high_sev == true)
      inbox_items = relevant_bulletins.select do |b|
        is_muted = muted_set.include?(b.canonical_feed_id)
        is_provisional = provisional_only_feed_ids.include?(b.canonical_feed_id)
        (!is_muted && !is_provisional) || b.is_high_sev
      end.map do |b|
        feed = feed_by_id[b.canonical_feed_id]
        from_muted_feed = muted_set.include?(b.canonical_feed_id)
        from_provisional_guess = provisional_only_feed_ids.include?(b.canonical_feed_id)
        linked_devs = device_feed_links[b.canonical_feed_id]

        {
          external_id: b.external_id,
          feed_slug: feed&.slug,
          bulletin_type: b.bulletin_type,
          is_high_sev: b.is_high_sev,
          broke_through_mute: from_muted_feed && b.is_high_sev,
          matched_by_guess: from_provisional_guess,
          candidate_models: from_provisional_guess ? linked_devs.flat_map { |d| Array(d.candidate_models) }.uniq : [],
          title: is_stn ? b.stn_title : b.pro_title,
          body: is_stn ? b.stn_body : b.pro_body,
          published_at: b.published_at
        }
      end

      confirmed_feeds = matched_feeds.reject { |f| provisional_only_feed_ids.include?(f.id) }
      active_feed_count = confirmed_feeds.count { |f| !muted_set.include?(f.id) }
      muted_feed_count = matched_feeds.count { |f| muted_set.include?(f.id) }

      {
        ai_summary: {
          active_feed_count: active_feed_count,
          muted_feed_count: muted_feed_count,
          provisional_feed_count: provisional_only_feed_ids.size,
          muted_high_sev_override_count: muted_high_sev_count,
          provisional_high_sev_count: provisional_high_sev_count,
          bullets: ai_bullets
        },
        matched_feeds: feed_summaries,
        inbox: inbox_items
      }
    end
  end
end
