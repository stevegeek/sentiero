# frozen_string_literal: true

require_relative "../events"
require_relative "../stats"
require_relative "../bounded"

module Sentiero
  module Analytics
    # Per-URL scroll depth across page segments and windows.
    #
    # rrweb Metas carry the viewport height but NOT the document height, so page
    # height is ESTIMATED as the deepest (max scroll + viewport) any sample
    # reached — exact when somebody read to the end, a lower bound otherwise.
    # Viewport-less samples fall back to pixels (no percentage derivable).
    #
    # Per window: #observe each segment, then #flush_window once to commit each
    # URL's deepest segment as ONE sample.
    class ScrollCollector
      include Events
      include Stats
      include Bounded

      DISTRIBUTION_BINS = %w[0-25 25-50 50-75 75-100].freeze

      attr_reader :capped

      # max_urls: nil unbounded; an Integer caps distinct URLs, flipping #capped.
      def initialize(max_urls: nil)
        @max_urls = max_urls
        @samples_by_url = {} # url => [{max_y:, viewport_height:}, ...]
        @window = {} # url => deepest segment depth in the current window
        @capped = false
      end

      # Deepest segment per url wins; segments with no scroll are ignored.
      def observe(url, segment)
        depth = segment_depth(segment)
        return unless depth

        current = @window[url]
        @window[url] = depth if current.nil? || depth[:max_y] > current[:max_y]
      end

      # One sample per (url, window): the deepest of the window's segments, then resets.
      def flush_window
        @window.each do |url, depth|
          samples = bounded_fetch(@samples_by_url, url, @max_urls) { [] }
          if samples.nil?
            @capped = true
            next
          end
          samples << depth
        end
        @window = {}
      end

      # nil when nothing was recorded for the URL.
      def summarize(url)
        samples = @samples_by_url[url]
        return nil unless samples && !samples.empty?

        summarize_samples(samples)
      end

      def pages
        @samples_by_url.transform_values { |samples| summarize_samples(samples) }
      end

      private

      def segment_depth(segment)
        max_y = segment.filter_map { |event| scroll_y(event) }.max || 0
        return nil unless max_y > 0

        {max_y: max_y, viewport_height: viewport_height(segment)}
      end

      # Only the document scroll (node id nil or 1) counts as page depth; inner
      # scroll containers (id > 1) would otherwise inflate it. Mirrors
      # ClickCollector#document_scroll_y so both agree on "page scroll".
      def scroll_y(event)
        return nil unless event["type"] == INCREMENTAL

        data = event["data"]
        return nil unless data.is_a?(Hash) && data["source"] == SOURCE_SCROLL

        id = data["id"]
        return nil unless id.nil? || id == 1

        y = data["y"]
        y.is_a?(Numeric) ? y : nil
      end

      def viewport_height(segment)
        height = meta_event(segment)&.dig("data", "height")
        (height.is_a?(Numeric) && height > 0) ? height : nil
      end

      def meta_event(events)
        events.find { |event| event["type"] == META && event["data"].is_a?(Hash) }
      end

      def summarize_samples(samples)
        pixels = samples.map { |sample| sample[:max_y] }
        page_height = samples.filter_map { |sample| viewport_bottom(sample) }.max
        pcts = samples.filter_map { |sample| depth_pct(sample, page_height) }

        {
          session_count: samples.size,
          avg_depth_px: mean(pixels),
          avg_depth_pct: pcts.empty? ? nil : mean(pcts),
          page_height_px: page_height,
          fold_lines: fold_lines(pcts),
          distribution: distribution(samples, page_height)
        }
      end

      def viewport_bottom(sample)
        height = sample[:viewport_height]
        height ? sample[:max_y] + height : nil
      end

      def depth_pct(sample, page_height)
        bottom = viewport_bottom(sample)
        return nil unless bottom && page_height

        [bottom.to_f / page_height * 100, 100.0].min
      end

      def fold_lines(pcts)
        return {p50: nil, p75: nil, p90: nil} if pcts.empty?

        sorted = pcts.sort
        {p50: percentile(sorted, 50), p75: percentile(sorted, 75), p90: percentile(sorted, 90)}
      end

      # Viewport-less samples (no percentage derivable) fall back to pixels
      # relative to the deepest sample so they still land in a bin.
      def distribution(samples, page_height)
        bins = DISTRIBUTION_BINS.to_h { |label| [label, 0] }
        deepest_px = samples.map { |sample| sample[:max_y] }.max

        samples.each do |sample|
          pct = depth_pct(sample, page_height) || (sample[:max_y].to_f / deepest_px * 100)
          bins[bin_for(pct)] += 1
        end
        bins
      end

      def bin_for(pct)
        index = (pct / 25.0).ceil.clamp(1, 4) - 1
        DISTRIBUTION_BINS[index]
      end
    end
  end
end
