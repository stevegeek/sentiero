# frozen_string_literal: true

require_relative "analyzer"
require_relative "frustration/detectors"

module Sentiero
  module Analytics
    # Cross-session frustration signals per page URL: rage clicks (bursts at
    # the same spot) and dead clicks (clicks the page never responds to), plus
    # top rage-clicked elements and per-incident replay links.
    #
    # Detection itself lives in Frustration::Detectors (pure Ruby ports of the
    # JS detectors, frontend/src/dashboard/frustration.js, pinned by ported
    # tests so the two can't drift). Over the detectors' raw dead clicks this
    # class layers cross-session aggregation and a de-noising pass: an
    # app-level custom event in the dead window counts as a page response; the
    # final click of a segment navigated away from is withdrawn; an
    # error-coincident dead click is kept and tagged kind: "error".
    class FrustrationAnalyzer < Analyzer
      # Custom-event tag carrying the clicked element's CSS selector.
      CLICK_TAG = "__click"

      # Recorder-internal annotation prefix and the browser JS-error tag;
      # neither proves the page responded to a click.
      INTERNAL_TAG_PREFIX = "__"
      ERROR_TAG = "error"

      # Max ms a "__click" annotation may sit from a rage cluster's first
      # click and still be attributed to it.
      NEAREST_CLICK_TOLERANCE_MS = 500

      # Accumulation caps during the scan (sessions scan newest-first).
      MAX_URLS = 200
      MAX_SELECTORS_PER_URL = 200
      MAX_INCIDENTS_PER_URL = 20
      TOP_SELECTORS_LIMIT = 10

      # Stable entry point for callers outside this class (EngagementAnalyzer,
      # PageReportAnalyzer) that only need raw detection, not the cross-session
      # aggregation below.
      def self.detect_frustration_events(events) = Frustration::Detectors.detect_frustration_events(events)

      # Detectors run over the FULL window (their response semantics span page
      # boundaries by design); each incident is then attributed to the page
      # segment its click happened on.
      def analyze(limit: nil, since: nil, until_time: nil)
        pages = {}
        accumulation_capped = false

        _scanned, hit_cap = scan_sessions(limit: limit, since: since, until_time: until_time) do |summary, window_id, events|
          incidents = Frustration::Detectors.detect_frustration_events(events)
          next if incidents.empty?

          segments = page_segments(events)
          incidents = refine_incidents(incidents, segments)
          next if incidents.empty?

          annotations = click_annotations(events)

          incidents.each do |incident|
            page = page_for(pages, incident[:url])
            unless page
              accumulation_capped = true
              next
            end

            accumulation_capped = true unless record_incident(page, incident, summary[:session_id], window_id, annotations)
            page[:session_ids][summary[:session_id]] = true
          end
        end

        {
          pages: pages.transform_values { |page| summarize(page) },
          was_truncated: accumulation_capped || hit_cap
        }
      end

      private

      def page_segments(events)
        segments = []
        each_page_segment(events) do |url, segment, _anchor|
          segments << [url, segment]
        end
        segments
      end

      # Attributes each incident to its click's segment and de-noises dead clicks
      # (class-comment rules). Object identity (not timestamp) locates the segment,
      # avoiding mis-attribution at a same-millisecond Meta boundary. Drops
      # incidents on URL-less segments or withdrawn by the de-noise rules.
      def refine_incidents(incidents, segments)
        incidents.filter_map do |incident|
          index = segments.index { |(_url, segment)| segment.any? { |e| e.equal?(incident[:event]) } }
          url = index && segments[index][0]
          next nil unless url

          kind = nil
          if incident[:subtype] == "dead_click"
            segment = segments[index][1]
            next nil if custom_response?(segment, incident[:timestamp])

            if error_coincident?(segment, incident[:timestamp])
              kind = "error"
            elsif navigated_away_final_click?(segments, index, incident[:event])
              next nil
            end
          end

          incident.merge(url: url, kind: kind)
        end
      end

      # An app-level custom event in the dead window means the page reacted
      # (the pure detectors only see META/mutation/input).
      def custom_response?(segment, click_ts)
        any_custom_in_window?(segment, click_ts) do |tag|
          !tag.start_with?(INTERNAL_TAG_PREFIX) && tag != ERROR_TAG
        end
      end

      def error_coincident?(segment, click_ts)
        any_custom_in_window?(segment, click_ts) { |tag| tag == ERROR_TAG }
      end

      # Any CUSTOM event whose tag satisfies the block within [click_ts, +DEAD_WINDOW_MS].
      # Same-tick INclusive: the recorder emits navigation/error customs in the same
      # tick as the native click, which the detectors' strictly-after rule would miss.
      def any_custom_in_window?(segment, click_ts)
        deadline = click_ts + Frustration::Detectors::DEAD_WINDOW_MS
        segment.any? do |event|
          next false unless event["type"] == CUSTOM

          ts = event["timestamp"]
          next false unless ts.is_a?(Numeric) && ts >= click_ts && ts <= deadline

          tag = event.dig("data", "tag")
          tag.is_a?(String) && yield(tag)
        end
      end

      # The last click of a segment that's navigated away from likely CAUSED a
      # navigation slower than the dead window, so its dead verdict is withdrawn.
      # The window's FINAL segment is exempt: a window that just ends proves no
      # navigation, and the inert-button bounce is the signal this page exists for.
      def navigated_away_final_click?(segments, index, event)
        return false if index >= segments.size - 1

        # Reuse the detectors' click? so "last click" can't drift from theirs.
        last_click = segments[index][1].reverse_each.find { |e| Frustration::Detectors.click?(e) }
        last_click.equal?(event)
      end

      # Page accumulator for a URL, or nil when the URL-row cap is full.
      def page_for(pages, url)
        bounded_fetch(pages, url, MAX_URLS) do
          {rage_count: 0, dead_count: 0, session_ids: {}, selectors: Hash.new(0), incidents: []}
        end
      end

      # [timestamp, selector] pairs from the window's "__click" annotations.
      def click_annotations(events)
        events.filter_map do |event|
          next unless event["type"] == CUSTOM
          data = event["data"]
          next unless data.is_a?(Hash) && data["tag"] == CLICK_TAG

          selector = data.dig("payload", "selector")
          next unless selector.is_a?(String) && !selector.empty?
          next unless event["timestamp"].is_a?(Numeric)

          [event["timestamp"], selector]
        end
      end

      # Returns false when the per-URL selector cap swallowed a new selector (the
      # only lossy path — the incident-row cap is a display bound, counts stay complete).
      def record_incident(page, incident, session_id, window_id, annotations)
        selector = nil
        selector_capped = false

        if incident[:subtype] == "rage_click"
          page[:rage_count] += 1
          selector = nearest_selector(annotations, incident[:timestamp])
          if selector
            if page[:selectors].key?(selector) || page[:selectors].size < MAX_SELECTORS_PER_URL
              page[:selectors][selector] += 1
            else
              selector_capped = true
            end
          end
        else
          page[:dead_count] += 1
        end

        if page[:incidents].size < MAX_INCIDENTS_PER_URL
          page[:incidents] << {
            subtype: incident[:subtype],
            session_id: session_id,
            window_id: window_id,
            offset_ms: [incident[:offset], 0].max.round,
            count: incident[:count],
            selector: selector,
            kind: incident[:kind]
          }
        end

        !selector_capped
      end

      # Selector of the "__click" annotation nearest timestamp within
      # NEAREST_CLICK_TOLERANCE_MS; nil when nothing is close enough.
      def nearest_selector(annotations, timestamp)
        nearest = annotations.min_by { |(ts, _selector)| (ts - timestamp).abs }
        return nil unless nearest
        ((nearest[0] - timestamp).abs <= NEAREST_CLICK_TOLERANCE_MS) ? nearest[1] : nil
      end

      def summarize(page)
        {
          rage_count: page[:rage_count],
          dead_count: page[:dead_count],
          sessions_affected: page[:session_ids].size,
          top_selectors: top_selectors(page[:selectors]),
          incidents: page[:incidents]
        }
      end

      def top_selectors(selectors)
        top_counts(selectors, limit: TOP_SELECTORS_LIMIT)
          .map { |selector, count| {selector: selector, count: count} }
      end
    end
  end
end
