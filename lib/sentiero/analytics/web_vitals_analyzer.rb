# frozen_string_literal: true

require_relative "analyzer"
require_relative "collectors/vitals_collector"

module Sentiero
  module Analytics
    # Aggregates Web Vitals per page URL, scanning the store on read. The recorder
    # emits one "__perf" custom event per metric report carrying {metric, value,
    # rating}; ratings come from the client web-vitals library and are tallied
    # as-is. Per-segment math (last-wins collapse, rating histogram, worst-sample)
    # lives in VitalsCollector, shared with PageReportAnalyzer.
    class WebVitalsAnalyzer < Analyzer
      # Cap on distinct URLs tracked; sessions scan newest-first, so the cap keeps
      # the most recently visited URLs.
      MAX_URLS = 200

      MAX_SAMPLES_PER_METRIC = 2000

      # Samples are attributed per page segment so each report lands on the page it
      # measured. Within a segment, repeated reports of the same metric collapse to
      # the LAST one (one sample == one page view's final value) so re-emitted
      # candidates and reloads cannot inflate counts or skew percentiles.
      def analyze(limit: nil, since: nil, until_time: nil)
        pages = {} # url => VitalsCollector
        accumulation_capped = false

        _scanned, hit_cap = scan_sessions(limit: limit, since: since, until_time: until_time) do |summary, window_id, events|
          each_page_segment(events) do |url, segment, anchor|
            next unless url

            collector = collector_for(pages, url)
            unless collector
              accumulation_capped = true
              next
            end

            collector.collect(segment, session_id: summary[:session_id], window_id: window_id, anchor: anchor)
            accumulation_capped = true if collector.capped
          end
        end

        {
          pages: pages.transform_values(&:summarize),
          was_truncated: accumulation_capped || hit_cap
        }
      end

      private

      # VitalsCollector for a URL, or nil when the URL-row cap is full.
      def collector_for(pages, url)
        bounded_fetch(pages, url, MAX_URLS) { VitalsCollector.new(max_samples: MAX_SAMPLES_PER_METRIC) }
      end
    end
  end
end
