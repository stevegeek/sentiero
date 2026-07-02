# frozen_string_literal: true

require_relative "events"
require_relative "stats"
require_relative "bounded"
require_relative "entry_attribution"

module Sentiero
  # Compute-on-read analytics: query the store and aggregate at request time.
  module Analytics
    class Analyzer
      include Events
      include Stats
      include Bounded
      include EntryAttribution

      attr_reader :store

      def initialize(store = Sentiero.store)
        @store = store
      end

      private

      # The standard bounded session scan: yields each window's
      # [summary, window_id, events] up to the scan cap, and returns
      # [sessions_scanned, hit_cap]. Counts DISTINCT sessions (not windows), so
      # `hit_cap` is correct even when a session spans several windows. Callers
      # build was_truncated as `collector.capped || hit_cap`.
      def scan_sessions(limit: nil, since: nil, until_time: nil)
        scan_cap = limit || store.limits.analytics_max_scan_sessions
        seen = {}
        store.each_session_events(limit: scan_cap, since: since, until_time: until_time) do |summary, window_id, events|
          seen[summary[:session_id]] = true
          yield summary, window_id, events
        end
        [seen.size, seen.size >= scan_cap]
      end

      def duration_ms(summary)
        first = summary[:first_event_at]
        last = summary[:last_event_at]
        return nil unless first && last

        (last - first).abs
      end

      def meta_event(events)
        events.find { |event| event["type"] == META && event["data"].is_a?(Hash) }
      end

      # Splits a window's events into per-page segments on Meta href boundaries
      # (one non-SPA window spans every page). Yields [url, segment_events,
      # anchor_ts]; consecutive same-href Metas (same-URL reloads) stay in one
      # segment. anchor_ts is the WINDOW's first timestamp for every segment:
      # replay deep-links (?t=offset) are window-relative, never segment-local.
      def each_page_segment(events)
        return if events.empty?

        anchor_ts = events.first&.fetch("timestamp", nil)

        boundaries = [] # [start_index, url] per href change
        events.each_with_index do |event, index|
          url = meta_href(event)
          next unless url

          boundaries << [index, url] if boundaries.empty? || boundaries.last[1] != url
        end

        if boundaries.empty?
          yield nil, events, anchor_ts
          return
        end

        boundaries.each_with_index do |(start, url), i|
          start = 0 if i.zero? # pre-first-Meta events belong to the first page
          stop = boundaries[i + 1]&.first || events.size
          yield url, events[start...stop], anchor_ts
        end
      end

      def meta_href(event)
        return nil unless event.is_a?(Hash) && event["type"] == META

        data = event["data"]
        href = data.is_a?(Hash) ? data["href"] : nil
        (href.is_a?(String) && !href.empty?) ? href : nil
      end
    end
  end
end
