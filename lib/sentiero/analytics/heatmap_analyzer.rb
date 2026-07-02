# frozen_string_literal: true

require_relative "analyzer"
require_relative "collectors/click_collector"

module Sentiero
  module Analytics
    # Aggregates click coordinates for a single page URL into a normalized density
    # grid plus a most-clicked-elements table. The per-segment density math lives
    # in ClickCollector (shared with PageReportAnalyzer).
    class HeatmapAnalyzer < Analyzer
      CLICK_TAG = ClickCollector::CLICK_TAG
      GRID_SIZE = ClickCollector::GRID_SIZE

      TOP_ELEMENTS_LIMIT = 20
      MAX_URLS = 200

      # Clicks are attributed per page segment (Meta-href boundaries).
      def analyze(target_url, limit: nil, since: nil, until_time: nil)
        clicks = ClickCollector.new
        representative = nil

        _scanned, hit_cap = scan_sessions(limit: limit, since: since, until_time: until_time) do |summary, window_id, events|
          session_id = summary[:session_id]

          each_page_segment(events) do |url, segment, _anchor|
            next unless url == target_url

            added = clicks.collect(segment)
            representative ||= {session_id: session_id, window_id: window_id} unless added.nil?
          end
        end

        {
          clicks_by_bucket: clicks.buckets,
          top_elements: top_elements(clicks.selectors),
          total_clicks: clicks.total,
          representative_window: representative,
          was_truncated: hit_cap
        }
      end

      def build_heatmap_table(since: nil, until_time: nil)
        selectors_by_url = {}

        scan_sessions(since: since, until_time: until_time) do |_summary, _window_id, events|
          each_page_segment(events) do |url, segment, _anchor|
            next unless url

            selectors = selectors_by_url[url]
            if selectors.nil?
              next if selectors_by_url.size >= MAX_URLS
              selectors = selectors_by_url[url] = Hash.new(0)
            end
            segment.each { |event| tally_selector(selectors, event) }
          end
        end

        selectors_by_url
          .sort_by { |url, _selectors| url }
          .to_h { |url, selectors| [url, top_elements(selectors)] }
      end

      def recorded_urls
        urls = {}

        scan_sessions do |_summary, _window_id, events|
          each_page_segment(events) do |url, _segment, _anchor|
            urls[url] = true if url && (urls.key?(url) || urls.size < MAX_URLS)
          end
        end

        urls.keys
      end

      private

      def tally_selector(selectors, event)
        return unless event["type"] == CUSTOM
        data = event["data"]
        return unless data.is_a?(Hash) && data["tag"] == CLICK_TAG

        selector = data.dig("payload", "selector")
        selectors[selector] += 1 if selector.is_a?(String) && !selector.empty?
      end

      def top_elements(selectors)
        top_counts(selectors, limit: TOP_ELEMENTS_LIMIT)
          .map { |selector, count| {selector: selector, count: count} }
      end
    end
  end
end
