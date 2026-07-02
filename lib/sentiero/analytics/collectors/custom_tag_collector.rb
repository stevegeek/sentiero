# frozen_string_literal: true

require_relative "../events"
require_relative "../bounded"
require_relative "../stats"

module Sentiero
  module Analytics
    # Custom-event tag tally across page segments. The single definition of
    # which tags are "internal" and how the rest are counted and ranked.
    class CustomTagCollector
      include Events
      include Bounded
      include Stats

      # Recorder-internal annotations (__perf, __click, …); never on the panel.
      INTERNAL_TAG_PREFIX = "__"
      # The JS-error tag is also internal — it has its own panel.
      ERROR_TAG = "error"
      MAX_CUSTOM_TAGS = 200

      attr_reader :tags, :capped

      # max_tags: nil unbounded; an Integer caps distinct tags, flipping #capped.
      def initialize(max_tags: nil)
        @max_tags = max_tags
        @tags = Hash.new(0)
        @capped = false
      end

      def internal_tag?(tag)
        tag.start_with?(INTERNAL_TAG_PREFIX) || tag == ERROR_TAG
      end

      # Returns true when counted, false when internal or capped — callers gate
      # per-tag side-effects on this.
      def tally(tag)
        return false if internal_tag?(tag)

        counted = bounded_increment(@tags, tag, @max_tags)
        @capped = true unless counted
        counted
      end

      def collect(segment)
        segment.each do |event|
          next unless event["type"] == CUSTOM

          tag = event.dig("data", "tag")
          next unless tag.is_a?(String) && !tag.empty?

          tally(tag)
        end
      end

      def top(n)
        top_counts(@tags, limit: n).map { |tag, count| {tag: tag, count: count} }
      end
    end
  end
end
