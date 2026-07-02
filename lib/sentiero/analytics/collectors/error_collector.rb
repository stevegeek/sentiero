# frozen_string_literal: true

require_relative "../events"
require_relative "../stats"
require_relative "../bounded"

module Sentiero
  module Analytics
    # Per-URL error grouping across page segments. Groups JS errors by a
    # normalized key (see group_key) so messages differing only by an
    # id/count/line number collapse into one row. Each occurrence records
    # offset_ms from the window's first event so the UI can deep-link via ?t=.
    # The three helpers are class methods so ErrorDiscovery can reuse them with
    # its own group shape without instantiating an accumulator.
    class ErrorCollector
      include Events
      include Stats
      include Bounded

      ERROR_TAG = "error"
      MAX_KEY_LENGTH = 200

      attr_reader :groups, :capped

      # Integer caps distinct groups (flips #capped) / occurrences per group; nil unbounded.
      def initialize(max_groups: nil, max_occurrences: nil)
        @max_groups = max_groups
        @max_occurrences = max_occurrences
        @groups = {}
        @capped = false
      end

      # anchor is the window's first-event timestamp; offset_ms is relative to it
      # so replay ?t= deep-links stay consistent across segments of the window.
      def collect(segment, session_id:, window_id:, anchor:)
        segment.each do |event|
          next unless self.class.error_event?(event)

          message = self.class.extract_message(event)
          key = self.class.group_key(message)

          group = bounded_fetch(@groups, key, @max_groups) { {message: message, count: 0, occurrences: []} }
          if group.nil?
            @capped = true
            next
          end

          group[:count] += 1

          if @max_occurrences.nil? || group[:occurrences].size < @max_occurrences
            group[:occurrences] << {
              session_id: session_id,
              window_id: window_id,
              offset_ms: offset_ms(anchor, event["timestamp"])
            }
          end
        end
      end

      def summarize
        {
          groups: @groups.values
            .sort_by { |g| -g[:count] }
            .map { |g| {message: g[:message], count: g[:count], occurrences: g[:occurrences]} },
          total: @groups.values.sum { |g| g[:count] }
        }
      end

      def self.error_event?(event)
        return false unless event["type"] == CUSTOM

        data = event["data"]
        data.is_a?(Hash) && data["tag"] == ERROR_TAG
      end

      def self.group_key(message)
        message.lines.first.to_s.strip.gsub(/\d+/, "#")[0, MAX_KEY_LENGTH]
      end

      def self.extract_message(event)
        payload = event.dig("data", "payload")
        message = payload.is_a?(Hash) ? payload["message"] : nil
        return "Unknown error" if message.nil? || message.to_s.strip.empty?

        message.to_s
      end
    end
  end
end
