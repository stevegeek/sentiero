# frozen_string_literal: true

require "digest"
require_relative "analyzer"
require_relative "collectors/error_collector"
require_relative "../user_agent"

module Sentiero
  module Analytics
    # Groups captured JS errors (custom events tagged "error") by a normalized
    # message pattern so the same error collapses into one row. Each occurrence
    # carries offset_ms from its window's first event for the player's ?t= deep
    # link. Pure transforms are shared with PageReportAnalyzer via ErrorCollector.
    class ErrorDiscovery < Analyzer
      MAX_OCCURRENCES_PER_GROUP = 50

      MAX_FACET_VALUES = 50

      def grouped_errors(sort_by: "count", since: nil, until_time: nil)
        groups = {}

        _scanned, hit_cap = scan_sessions(since: since, until_time: until_time) do |summary, window_id, events|
          collect_window(groups, summary, window_id, events)
        end

        {
          groups: sort_groups(groups.values, sort_by),
          was_truncated: hit_cap
        }
      end

      private

      def collect_window(groups, summary, window_id, events)
        anchor = events.first&.fetch("timestamp", nil)

        events.each do |event|
          next unless ErrorCollector.error_event?(event)

          add_occurrence(groups, summary, window_id, anchor, event)
        end
      end

      def add_occurrence(groups, summary, window_id, anchor, event)
        payload = error_payload(event)
        message = ErrorCollector.extract_message(event)
        timestamp = event["timestamp"]

        key = ErrorCollector.group_key(message)
        group = groups[key] ||= new_group(key, message, payload)
        group[:count] += 1
        group[:last_seen_at] = [group[:last_seen_at], timestamp].compact.max
        tally_facets(group, summary[:metadata] || {})
        return if group[:occurrences].size >= MAX_OCCURRENCES_PER_GROUP

        group[:occurrences] << {
          session_id: summary[:session_id],
          window_id: window_id,
          timestamp: timestamp,
          offset_ms: offset_ms(anchor, timestamp)
        }
      end

      def error_payload(event)
        payload = event.dig("data", "payload")
        payload.is_a?(Hash) ? payload : {}
      end

      def new_group(key, message, payload)
        {
          id: Digest::SHA1.hexdigest(key),
          message: message,
          source: source_of(payload),
          line: line_of(payload),
          count: 0,
          last_seen_at: nil,
          browsers: Hash.new(0),
          devices: Hash.new(0),
          pages: Hash.new(0),
          occurrences: []
        }
      end

      def tally_facets(group, metadata)
        user_agent = metadata["userAgent"]
        bounded_tally(group[:browsers], UserAgent.browser(user_agent))
        bounded_tally(group[:devices], UserAgent.device(user_agent))
        bounded_tally(group[:pages], metadata["url"])
      end

      def bounded_tally(counts, value)
        return unless value.is_a?(String) && !value.empty?
        return if !counts.key?(value) && counts.size >= MAX_FACET_VALUES

        counts[value] += 1
      end

      def source_of(payload)
        source = payload["source"]
        (source.is_a?(String) && !source.empty?) ? source : nil
      end

      def line_of(payload)
        line = payload["lineno"]
        line.is_a?(Integer) ? line : nil
      end

      def sort_groups(groups, sort_by)
        case sort_by
        when "recency"
          groups.sort_by { |group| -(group[:last_seen_at] || 0) }
        else
          groups.sort_by { |group| [-group[:count], -(group[:last_seen_at] || 0)] }
        end
      end
    end
  end
end
