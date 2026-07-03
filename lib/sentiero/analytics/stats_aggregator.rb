# frozen_string_literal: true

require_relative "analyzer"
require_relative "collectors/custom_tag_collector"
require_relative "../user_agent"

module Sentiero
  module Analytics
    class StatsAggregator < Analyzer
      # Required here, not at file top: ResultBuilder reopens this class, and
      # requiring it before the `< Analyzer` superclass is established would
      # raise a superclass mismatch.
      require_relative "stats_aggregator/result_builder"

      TOP_LIST_LIMIT = 10
      TOP_TAGS_LIMIT = 20
      TOP_PROBLEMS_LIMIT = 5

      NAVIGATION_TAG = "navigation"

      INTERNAL_METADATA_KEYS = %w[userAgent url referrer viewport has_errors entry_url entry_referrer
        geo_country geo_city geo_region geo_timezone].freeze

      MAX_NAV_KEYS = 200
      MAX_METADATA_KEYS = 50
      MAX_METADATA_VALUES_PER_KEY = 50
      MAX_TAG_SERIES_KEYS = 200
      MAX_OVERLAY_PROBLEMS = 200
      MAX_OCCURRENCES_PER_PROBLEM = 500
      MAX_GEO_VALUES = 200

      DURATION_BUCKETS = [
        ["0-30s", 30_000],
        ["30s-2m", 120_000],
        ["2-5m", 300_000],
        ["5-15m", 900_000],
        ["15m+", nil]
      ].freeze

      WEEK_BUCKET_THRESHOLD_DAYS = 45

      def aggregate(range_days: 30, since: nil, until_time: nil, server_exception_overlay: false)
        scan_cap = store.limits.analytics_max_scan_sessions
        since ||= default_since(range_days, until_time)

        acc = new_accumulator(since, until_time)
        seen_sessions = {}

        store.each_session_events(limit: scan_cap, since: since, until_time: until_time) do |summary, _window_id, events|
          accumulate_window(acc, seen_sessions, summary, events)
        end

        finalize(acc, seen_sessions, scan_cap, overlay: server_exception_overlay)
      end

      # Derives BOTH the current-window aggregate and the equal-length
      # prior-window aggregate from a SINGLE widened scan over
      # [prior_since, until_time], partitioning each session into the current or
      # prior bucket by its updated_at. Returns {current:, prior:}; prior is nil
      # when no comparison is possible (zero-length window) or when the widened
      # scan is truncated — in which case the current aggregate is recomputed
      # from an exact single-window scan so the displayed numbers stay correct
      # (deltas are dropped on truncation anyway).
      def aggregate_with_prior(range_days: 30, since: nil, until_time: nil)
        scan_cap = store.limits.analytics_max_scan_sessions
        since ||= default_since(range_days, until_time)
        window_until = until_time || Time.now.to_f
        span = window_until - since

        return {current: aggregate(since: since, until_time: until_time, server_exception_overlay: true), prior: nil} unless span > 0

        prior_since = since - span
        prior_until = since - 0.001

        current = {acc: new_accumulator(since, until_time), seen: {}}
        prior = {acc: new_accumulator(prior_since, prior_until), seen: {}}

        store.each_session_events(limit: scan_cap, since: prior_since, until_time: until_time) do |summary, _window_id, events|
          bucket = (summary[:updated_at] >= since) ? current : prior
          accumulate_window(bucket[:acc], bucket[:seen], summary, events)
        end

        if current[:seen].size + prior[:seen].size >= scan_cap
          return {current: aggregate(since: since, until_time: until_time, server_exception_overlay: true), prior: nil}
        end

        {
          current: finalize(current[:acc], current[:seen], scan_cap, overlay: true),
          prior: finalize(prior[:acc], prior[:seen], scan_cap, overlay: false)
        }
      end

      private

      def accumulate_window(acc, seen_sessions, summary, events)
        session_id = summary[:session_id]
        collect_session(acc, summary, seen_sessions) unless seen_sessions.key?(session_id)
        update_entry_candidate(seen_sessions[session_id], events)
        collect_events(acc, events)
      end

      def finalize(acc, seen_sessions, scan_cap, overlay:)
        tally_entries(acc, seen_sessions)
        overlay_truncated = overlay ? collect_server_overlay(acc) : false
        ResultBuilder.new(store).build(acc, seen_sessions.size, scan_cap, overlay_truncated)
      end

      # range_days - 1: the start day is itself one of the range_days buckets.
      def default_since(range_days, until_time)
        end_date = (until_time ? Time.at(until_time) : Time.now).utc.to_date
        start_date = end_date - (range_days - 1)
        Time.utc(start_date.year, start_date.month, start_date.day).to_f
      end

      # Mutable bag of the running tallies for one aggregate scan. A Struct (not a
      # Hash) so the ~24 fields are named accessors threaded through the tally_*
      # methods rather than string-typed acc.key lookups.
      Accumulator = Struct.new(
        :event_types, :custom_tags, :browser_tags, :browsers, :devices,
        :countries, :cities,
        :entry_pages, :entry_page_errors, :referrers, :duration_buckets,
        :total_events, :durations, :since, :until_time,
        :per_day_events, :per_day_sessions, :per_day_errors, :per_day_tags,
        :per_day_server_errors, :nav_internal, :nav_external, :nav_texts,
        :metadata_keys, :metadata_values, :sessions_with_errors,
        keyword_init: true
      )

      def new_accumulator(since, until_time)
        Accumulator.new(
          event_types: Hash.new(0),
          custom_tags: CustomTagCollector.new,
          browser_tags: Hash.new(0),
          browsers: Hash.new(0),
          devices: Hash.new(0),
          countries: Hash.new(0),
          cities: Hash.new(0),
          entry_pages: Hash.new(0),
          entry_page_errors: Hash.new(0),
          referrers: Hash.new(0),
          duration_buckets: DURATION_BUCKETS.to_h { |label, _| [label, 0] },
          total_events: 0,
          durations: [],
          since: since,
          until_time: until_time,
          per_day_events: Hash.new(0),
          per_day_sessions: Hash.new(0),
          per_day_errors: Hash.new(0),
          per_day_tags: {},
          per_day_server_errors: Hash.new(0),
          nav_internal: Hash.new(0),
          nav_external: Hash.new(0),
          nav_texts: Hash.new(0),
          metadata_keys: Hash.new(0),
          metadata_values: {},
          sessions_with_errors: 0
        )
      end

      # Runs once per session (windows share metadata and one duration).
      def collect_session(acc, summary, seen_sessions)
        metadata = summary[:metadata] || {}
        entry_url = metadata["entry_url"]
        seen_sessions[summary[:session_id]] = {
          entry_url: entry_url,
          # A real entry_url is authoritative; a first-Meta href may only claim
          # the slot when we started from nil.
          entry_anchor: entry_url ? -Float::INFINITY : nil,
          referrer: metadata["entry_referrer"] || metadata["referrer"],
          has_errors: !!metadata["has_errors"]
        }

        tally_browser_device(acc, metadata["userAgent"])
        tally_geo(acc, metadata)
        acc.sessions_with_errors += 1 if metadata["has_errors"]

        tally_metadata(acc, metadata)
        record_duration(acc, summary)
        record_session_day(acc, summary)
      end

      # Deferred until every window is seen: entry page is the first Meta href,
      # not the metadata URL the recorder overwrites on each navigation.
      # Same-origin referrers dropped so Top Referrers shows only acquisition.
      def tally_entries(acc, seen_sessions)
        seen_sessions.each_value do |state|
          entry_url = state[:entry_url]
          tally(acc.entry_pages, entry_url)
          tally(acc.entry_page_errors, entry_url) if state[:has_errors]

          tally(acc.referrers, state[:referrer]) unless same_origin?(state[:referrer], entry_url)
        end
      end

      # Values are tracked only for keys that survived the key cap.
      def tally_metadata(acc, metadata)
        metadata.each do |key, value|
          next unless key.is_a?(String) && !key.empty?
          next if INTERNAL_METADATA_KEYS.include?(key)
          next unless bounded_tally(acc.metadata_keys, key, MAX_METADATA_KEYS)

          values = acc.metadata_values[key] ||= Hash.new(0)
          bounded_tally(values, value.to_s, MAX_METADATA_VALUES_PER_KEY)
        end
      end

      def collect_events(acc, events)
        events.each do |event|
          next unless in_window?(acc, event["timestamp"])

          type = event["type"]
          acc.event_types[type] += 1
          acc.total_events += 1
          tally_custom_tag(acc, event) if type == CUSTOM
          record_event_day(acc, event)
          record_error_day(acc, event) if error_event?(event)
        end
      end

      # Clamps per-event tallies to [since, until_time]: an in-range session can
      # carry out-of-window events that must not inflate totals. Events without a
      # numeric timestamp are kept (unplaceable).
      def in_window?(acc, timestamp_ms)
        return true unless timestamp_ms.is_a?(Numeric)

        ts = timestamp_ms / 1000.0
        ts >= acc.since && (acc.until_time.nil? || ts <= acc.until_time)
      end

      def tally_browser_device(acc, user_agent)
        browser = UserAgent.browser(user_agent)
        device = UserAgent.device(user_agent)
        acc.browsers[browser] += 1 if browser
        acc.devices[device] += 1 if device
      end

      def tally_geo(acc, metadata)
        country = metadata["geo_country"]
        city = metadata["geo_city"]
        bounded_tally(acc.countries, country, MAX_GEO_VALUES) if country.is_a?(String) && !country.empty?
        bounded_tally(acc.cities, city, MAX_GEO_VALUES) if city.is_a?(String) && !city.empty?
      end

      def tally_custom_tag(acc, event)
        data = event["data"]
        return unless data.is_a?(Hash)
        tag = data["tag"]
        return unless tag.is_a?(String)

        tally_navigation(acc, data["payload"]) if tag == NAVIGATION_TAG

        # Branch on #tally's return so browser_tags and per-day series share its
        # gate (internal "__" annotations and the JS-error tag are excluded).
        return unless acc.custom_tags.tally(tag)

        acc.browser_tags[tag] += 1
        record_tag_day(acc, tag, event["timestamp"])
      end

      # New series bounded by MAX_TAG_SERIES_KEYS; existing tags count past it.
      def record_tag_day(acc, tag, timestamp_ms)
        date = day_string(timestamp_ms)
        return unless date

        series = acc.per_day_tags[tag]
        series = acc.per_day_tags[tag] = Hash.new(0) if series.nil? && acc.per_day_tags.size < MAX_TAG_SERIES_KEYS
        series[date] += 1 if series
      end

      def tally_navigation(acc, payload)
        return unless payload.is_a?(Hash)

        bucket = payload["external"] ? acc.nav_external : acc.nav_internal
        bounded_tally(bucket, payload["url"], MAX_NAV_KEYS)
        bounded_tally(acc.nav_texts, payload["text"], MAX_NAV_KEYS)
      end

      # Cap a per-value tally, ignoring blank/non-string values.
      def bounded_tally(counts, value, cap)
        return false unless value.is_a?(String) && !value.empty?

        bounded_increment(counts, value, cap)
      end

      def tally(counts, value)
        counts[value] += 1 if value.is_a?(String) && !value.empty?
      end

      def record_duration(acc, summary)
        first = summary[:first_event_at]
        last = summary[:last_event_at]
        return unless first && last

        duration = (last - first).abs
        acc.durations << duration
        label = bucket_label(duration)
        acc.duration_buckets[label] += 1
      end

      def bucket_label(duration_ms)
        label, _bound = DURATION_BUCKETS.find { |_label, bound| bound.nil? || duration_ms < bound }
        label
      end

      def record_session_day(acc, summary)
        date = day_string(summary[:first_event_at] || summary[:created_at])
        acc.per_day_sessions[date] += 1 if date
      end

      def record_event_day(acc, event)
        date = day_string(event["timestamp"])
        acc.per_day_events[date] += 1 if date
      end

      def error_event?(event)
        return false unless event["type"] == CUSTOM
        data = event["data"]
        data.is_a?(Hash) && data["tag"] == "error"
      end

      def record_error_day(acc, event)
        date = day_string(event["timestamp"])
        acc.per_day_errors[date] += 1 if date
      end

      # Per-day server-occurrence counts (occurrence timestamps are epoch
      # seconds); returns whether either cap was hit. since filters problems by
      # last_seen (safe: an in-window occurrence implies last_seen >= since).
      # until_time is applied per occurrence, not to list_problems, since a
      # still-active problem can own in-window occurrences.
      def collect_server_overlay(acc)
        since = acc.since
        until_time = acc.until_time
        problems = store.list_problems(project: nil, limit: MAX_OVERLAY_PROBLEMS, since: since)
        truncated = problems.size >= MAX_OVERLAY_PROBLEMS

        problems.each do |problem|
          occurrences = store.get_occurrences(problem[:id], after: since, limit: MAX_OCCURRENCES_PER_PROBLEM)
          truncated = true if occurrences.size >= MAX_OCCURRENCES_PER_PROBLEM

          occurrences.each do |occurrence|
            ts = occurrence["timestamp"].to_f
            next if until_time && ts > until_time
            acc.per_day_server_errors[Time.at(ts).utc.to_date.to_s] += 1
          end
        end

        truncated
      end

      def day_string(timestamp_ms)
        return nil unless timestamp_ms
        Time.at(timestamp_ms / 1000.0).utc.to_date.to_s
      rescue TypeError, ArgumentError
        nil
      end
    end
  end
end
