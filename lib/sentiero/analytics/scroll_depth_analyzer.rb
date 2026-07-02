# frozen_string_literal: true

require_relative "analyzer"
require_relative "collectors/scroll_collector"

module Sentiero
  module Analytics
    # Aggregates per-URL scroll depth across sessions (avg depth, fold lines,
    # distribution). Depth math lives in ScrollCollector; this drives it per URL.
    class ScrollDepthAnalyzer < Analyzer
      MAX_URLS = 200

      def analyze(limit: nil, since: nil, until_time: nil)
        scroll = ScrollCollector.new(max_urls: MAX_URLS)

        _scanned, hit_cap = scan_sessions(limit: limit, since: since, until_time: until_time) do |_summary, _window_id, events|
          each_page_segment(events) do |url, segment, _anchor|
            scroll.observe(url, segment) if url
          end
          scroll.flush_window
        end

        {
          pages: scroll.pages,
          was_truncated: scroll.capped || hit_cap
        }
      end
    end
  end
end
