# frozen_string_literal: true

require "date"

module Sentiero
  module Analytics
    # Per-day aggregations over an already-fetched list of custom events for the
    # events-index strips (level mix, numeric payload metrics). Operates purely on
    # the passed-in rows — it never re-reads the store, so the dashboard fetches
    # once and aggregates the full pre-pagination list here.
    class ServerEventMetrics
      # Most-recent day rows rendered in the events-index level-mix strip.
      LEVEL_MIX_MAX_DAYS = 30
      SERVER_EVENT_LEVELS = %w[debug info warn error].freeze

      # Cap on distinct payload keys offered in the metric_key dropdown.
      MAX_METRIC_KEYS = 50

      # Adapts BrowserEventDiscovery rows (symbol-keyed, rrweb epoch-MILLISECOND
      # timestamps) to the string-keyed, epoch-seconds shape these helpers expect,
      # so the browser tab can reuse them.
      def self.adapt_browser_rows(rows)
        rows.map do |row|
          {
            "name" => row[:name],
            "payload" => row[:payload],
            "timestamp" => row[:timestamp] && (row[:timestamp].to_f / 1000.0)
          }
        end
      end

      def initialize(events)
        @events = events
      end

      # Per-UTC-day level tallies. Returns [[date, {level => count}], ...]
      # ascending, capped to the most recent LEVEL_MIX_MAX_DAYS days with data.
      def level_mix_by_day
        days = Hash.new { |hash, key| hash[key] = Hash.new(0) }
        @events.each do |event|
          ts = event["timestamp"]&.to_f
          next unless ts && ts > 0
          level = event["level"]
          level = "info" unless SERVER_EVENT_LEVELS.include?(level)
          days[Time.at(ts).utc.to_date.to_s][level] += 1
        end
        days.sort_by { |date, _counts| date }.last(LEVEL_MIX_MAX_DAYS)
      end

      # Payload metrics are offered only when the rows share a single event name,
      # computed over those rows. `requested_key` is the user-selected metric key,
      # honored only if it names a numeric payload key.
      def payload_metric_locals(requested_key)
        single_name = single_event_name
        metric_keys = single_name ? numeric_payload_keys : []
        metric_key = metric_keys.include?(requested_key) ? requested_key : nil

        {
          single_name: single_name,
          metric_keys: metric_keys,
          metric_key: metric_key,
          metric_days: metric_key ? payload_metrics_by_day(metric_key) : []
        }
      end

      private

      # The shared event name when every row carries the same one — the
      # precondition for offering payload metrics.
      def single_event_name
        return nil if @events.empty?
        name = @events.first["name"]
        return nil unless name.is_a?(String) && !name.empty?
        (@events.all? { |event| event["name"] == name }) ? name : nil
      end

      # Payload keys observed with at least one Numeric value across the rows,
      # sorted; distinct keys capped at MAX_METRIC_KEYS.
      def numeric_payload_keys
        keys = {}
        @events.each do |event|
          payload = event["payload"]
          next unless payload.is_a?(Hash)
          payload.each do |key, value|
            next unless value.is_a?(Numeric)
            next if !keys.key?(key) && keys.size >= MAX_METRIC_KEYS
            keys[key] = true
          end
        end
        keys.keys.sort
      end

      # Per-UTC-day count/sum/min/max of one payload key (mirrors level_mix_by_day).
      # Non-numeric values are skipped and tallied separately. Returns
      # [[date, {count:, sum:, min:, max:, non_numeric:}], ...] ascending.
      def payload_metrics_by_day(key)
        days = Hash.new { |hash, date| hash[date] = {count: 0, sum: 0.0, min: nil, max: nil, non_numeric: 0} }
        @events.each do |event|
          ts = event["timestamp"]&.to_f
          next unless ts && ts > 0
          payload = event["payload"]
          next unless payload.is_a?(Hash) && payload.key?(key)

          day = days[Time.at(ts).utc.to_date.to_s]
          value = payload[key]
          unless value.is_a?(Numeric)
            day[:non_numeric] += 1
            next
          end

          day[:count] += 1
          day[:sum] += value
          day[:min] = day[:min] ? [day[:min], value].min : value
          day[:max] = day[:max] ? [day[:max], value].max : value
        end
        days.sort_by { |date, _metrics| date }.last(LEVEL_MIX_MAX_DAYS)
      end
    end
  end
end
