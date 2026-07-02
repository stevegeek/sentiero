# frozen_string_literal: true

require_relative "../events"
require_relative "../bounded"

module Sentiero
  module Analytics
    # Per-URL click density grid + element selectors across page segments. A
    # click's viewport y becomes a page coordinate by adding the latest scroll
    # offset, normalized against the estimated page height (deepest scroll +
    # viewport); x by viewport width. Both bucket into a GRID_SIZE x GRID_SIZE grid.
    class ClickCollector
      include Events
      include Bounded

      MOUSE_CLICK = 2

      # Carries the clicked element's CSS selector; rrweb's own click event only
      # references an internal node id, not a stable selector.
      CLICK_TAG = "__click"

      # Grid resolution per axis.
      GRID_SIZE = 20

      attr_reader :total, :buckets, :selectors, :capped

      def initialize(max_selectors: nil)
        @max_selectors = max_selectors
        @buckets = Hash.new(0)
        @selectors = Hash.new(0)
        @total = 0
        @capped = false
      end

      # Returns clicks added, or nil when the segment has no usable viewport
      # (callers branch on the nil).
      def collect(segment)
        viewport = viewport_size(segment)
        return nil unless viewport

        page_height = estimate_page_height(segment, viewport)
        scroll_y = 0
        added = 0

        segment.each do |event|
          scroll_y = 0 if event["type"] == META
          if (y = document_scroll_y(event))
            scroll_y = y
          end
          if click?(event)
            data = event["data"]
            @buckets[bucket(data["x"], data["y"] + scroll_y, viewport, page_height)] += 1
            added += 1
          end
          tally_selector(event)
        end

        @total += added
        added
      end

      private

      def viewport_size(events)
        meta = events.find { |event| event["type"] == META && event["data"].is_a?(Hash) }
        return nil unless meta

        width = meta.dig("data", "width")
        height = meta.dig("data", "height")
        return nil unless width.is_a?(Numeric) && height.is_a?(Numeric)
        return nil unless width > 0 && height > 0

        {width: width, height: height}
      end

      def estimate_page_height(segment, viewport)
        max_scroll = 0
        segment.each do |event|
          y = document_scroll_y(event)
          max_scroll = y if y && y > max_scroll
        end
        max_scroll + viewport[:height]
      end

      def document_scroll_y(event)
        return nil unless event["type"] == INCREMENTAL

        data = event["data"]
        return nil unless data.is_a?(Hash) && data["source"] == SOURCE_SCROLL

        id = data["id"]
        return nil unless id.nil? || id == 1

        y = data["y"]
        (y.is_a?(Numeric) && y >= 0) ? y : nil
      end

      def click?(event)
        return false unless event["type"] == INCREMENTAL

        data = event["data"]
        return false unless data.is_a?(Hash)

        data["source"] == SOURCE_MOUSE_INTERACTION &&
          data["type"] == MOUSE_CLICK &&
          data["x"].is_a?(Numeric) &&
          data["y"].is_a?(Numeric)
      end

      def bucket(x, page_y, viewport, page_height)
        [
          bucket_index(x, viewport[:width]),
          bucket_index(page_y, page_height)
        ]
      end

      def bucket_index(value, axis_length)
        index = (value.to_f / axis_length * GRID_SIZE).floor
        index.clamp(0, GRID_SIZE - 1)
      end

      def tally_selector(event)
        return unless event["type"] == CUSTOM

        data = event["data"]
        return unless data.is_a?(Hash) && data["tag"] == CLICK_TAG

        selector = data.dig("payload", "selector")
        return unless selector.is_a?(String) && !selector.empty?

        @capped = true unless bounded_increment(@selectors, selector, @max_selectors)
      end
    end
  end
end
