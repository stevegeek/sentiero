# frozen_string_literal: true

require_relative "analyzer"

module Sentiero
  module Analytics
    # Custom-event funnel: ordered step conversion across sessions. A session
    # reaches step N+1 only when an event with that tag occurs strictly after
    # the step-N match. Greedy-earliest chain matching is optimal for subsequence
    # reachability, so "how far did this session get" is exact.
    class FunnelAnalyzer < Analyzer
      # Excluded as a funnel step; has its own ErrorDiscovery surface.
      ERROR_TAG = "error"

      # Prefix of recorder-internal annotation tags (__perf, __click, ...).
      INTERNAL_TAG_PREFIX = "__"

      MAX_STEPS = 3

      MAX_TAGS = 200

      # Bounds per-session memory.
      MAX_STEP_EVENTS_PER_SESSION = 100

      MAX_EXAMPLES_PER_STEP = 10

      class << self
        def internal_tag?(tag)
          !tag.is_a?(String) || tag.empty? || tag.start_with?(INTERNAL_TAG_PREFIX) || tag == ERROR_TAG
        end

        def usable_steps(tags)
          Array(tags).reject { |tag| internal_tag?(tag) }.first(MAX_STEPS)
        end
      end

      # Fewer than 2 usable steps yields steps: [] but still collects vocabulary.
      def analyze(steps = [], limit: nil, since: nil, until_time: nil)
        steps = self.class.usable_steps(steps)
        steps = [] if steps.size < 2
        step_set = steps.uniq

        tags = {}
        sessions = {}
        accumulation_capped = false

        _scanned, hit_cap = scan_sessions(limit: limit, since: since, until_time: until_time) do |summary, window_id, events|
          session_id = summary[:session_id]

          anchor = events.first&.fetch("timestamp", nil)
          events.each do |event|
            tag = custom_tag(event)
            next unless tag

            accumulation_capped = true unless tally_tag(tags, tag)
            next if steps.empty? || !step_set.include?(tag)
            next unless event["timestamp"].is_a?(Numeric)

            entries = sessions[session_id] ||= []
            if entries.size >= MAX_STEP_EVENTS_PER_SESSION
              accumulation_capped = true
              next
            end

            entries << {
              tag: tag,
              timestamp: event["timestamp"],
              window_id: window_id,
              offset_ms: offset_ms(anchor, event["timestamp"])
            }
          end
        end

        {
          tags: tags.keys.sort,
          steps: summarize_steps(steps, sessions),
          was_truncated: accumulation_capped || hit_cap
        }
      end

      private

      def custom_tag(event)
        return nil unless event.is_a?(Hash) && event["type"] == CUSTOM
        data = event["data"]
        return nil unless data.is_a?(Hash)
        tag = data["tag"]
        self.class.internal_tag?(tag) ? nil : tag
      end

      # Returns false for a new tag past MAX_TAGS (signals truncation).
      def tally_tag(tags, tag)
        return true if tags.key?(tag)
        return false if tags.size >= MAX_TAGS
        tags[tag] = true
        true
      end

      def summarize_steps(steps, sessions)
        return [] if steps.empty?

        counts = Array.new(steps.size, 0)
        inter_times = Array.new(steps.size) { [] }
        examples = Array.new(steps.size) { [] }

        sessions.each do |session_id, entries|
          matches = chain(steps, entries)
          next if matches.empty?

          reached = matches.size
          (0...reached).each { |i| counts[i] += 1 }
          (1...reached).each { |i| inter_times[i] << matches[i][:timestamp] - matches[i - 1][:timestamp] }

          next unless reached < steps.size # converted sessions never drop off

          step_examples = examples[reached - 1]
          if step_examples.size < MAX_EXAMPLES_PER_STEP
            last = matches[reached - 1]
            step_examples << {session_id: session_id, window_id: last[:window_id], offset_ms: last[:offset_ms]}
          end
        end

        step_one = counts[0]
        steps.each_with_index.map do |tag, i|
          {
            tag: tag,
            sessions: counts[i],
            conversion_pct: step_one.zero? ? nil : (counts[i].to_f / step_one * 100).round(1),
            median_ms_from_previous: i.zero? ? nil : median(inter_times[i]),
            drop_off_examples: examples[i]
          }
        end
      end

      # Greedy earliest chain over time-sorted step events: an event matches when
      # its tag is the next pending step and its timestamp is strictly after the
      # previous match.
      def chain(steps, entries)
        matches = []
        last_ts = nil

        entries.sort_by { |entry| entry[:timestamp] }.each do |entry|
          break if matches.size >= steps.size
          next unless entry[:tag] == steps[matches.size]
          next unless last_ts.nil? || entry[:timestamp] > last_ts

          matches << entry
          last_ts = entry[:timestamp]
        end

        matches
      end

      def median(values)
        return nil if values.empty?
        percentile(values.sort, 50)
      end
    end
  end
end
