# frozen_string_literal: true

require_relative "../events"
require_relative "../bounded"

module Sentiero
  module Analytics
    # Per-segment frustration attribution. Attributes incidents to segments by
    # object identity (e.equal?(incident[:event])) so a same-millisecond Meta
    # boundary cannot mis-attribute one.
    #
    # IMPORTANT: works on the RAW detector output (before refine_incidents
    # de-noise), so dead_count may EXCEED /analytics/frustration for the same
    # URL. Intentional: completeness over precision (no rages a de-noise rule
    # might withdraw are missed).
    class FrustrationCollector
      include Events
      include Bounded

      # Recorder tag carrying the clicked element's CSS selector.
      CLICK_TAG = "__click"

      attr_reader :rage_count, :dead_count, :selectors, :capped

      def initialize(max_selectors: nil)
        @max_selectors = max_selectors
        @rage_count = 0
        @dead_count = 0
        @selectors = Hash.new(0)
        @capped = false
      end

      # Returns the number attributed to this segment.
      def collect(incidents, segment)
        return 0 if incidents.empty?

        attributed = 0
        incidents.each do |incident|
          next unless segment.any? { |e| e.equal?(incident[:event]) }

          if incident[:subtype] == "rage_click"
            @rage_count += 1
            selector = nearest_click_selector(segment, incident[:timestamp])
            if selector
              @capped = true unless bounded_increment(@selectors, selector, @max_selectors)
            end
          else
            @dead_count += 1
          end

          attributed += 1
        end
        attributed
      end

      private

      # Nearest "__click" selector by timestamp. No distance ceiling — the
      # segment is bounded to one page.
      def nearest_click_selector(segment, timestamp)
        nearest = nil
        nearest_distance = nil
        segment.each do |event|
          next unless event["type"] == CUSTOM

          data = event["data"]
          next unless data.is_a?(Hash) && data["tag"] == CLICK_TAG

          selector = data.dig("payload", "selector")
          next unless selector.is_a?(String) && !selector.empty?

          ts = event["timestamp"]
          next unless ts.is_a?(Numeric)

          distance = (ts - timestamp).abs
          if nearest_distance.nil? || distance < nearest_distance
            nearest_distance = distance
            nearest = selector
          end
        end
        nearest
      end
    end
  end
end
