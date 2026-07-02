# frozen_string_literal: true

require_relative "analyzer"

module Sentiero
  module Analytics
    # Cross-session newest-first listing of browser custom events (rrweb type==5)
    # excluding the "error" tag (errors have ErrorDiscovery). Each row carries
    # session/window + offset(ms) from window start for replay deep-links (?t=).
    class BrowserEventDiscovery < Analyzer
      ERROR_TAG = "error"

      MAX_ROWS = 500

      # Trim cap during the scan so a busy store can't balloon memory. Mid-scan
      # trimming is safe: it keeps the globally-newest seen, and newer events
      # from later sessions still get added and survive the next trim.
      ACCUMULATION_LIMIT = MAX_ROWS * 4

      def recent_events(since: nil, until_time: nil)
        rows = []
        truncated = false

        _scanned, hit_cap = scan_sessions(since: since, until_time: until_time) do |summary, window_id, events|
          anchor = events.first&.fetch("timestamp", nil)
          events.each do |event|
            next unless browser_event?(event)

            rows << build_row(summary, window_id, anchor, event)
          end

          next unless rows.size > ACCUMULATION_LIMIT

          rows.sort_by! { |r| -(r[:timestamp] || 0) }
          rows = rows.first(MAX_ROWS)
          truncated = true
        end

        rows.sort_by! { |r| -(r[:timestamp] || 0) }
        {
          rows: rows.first(MAX_ROWS),
          was_truncated: truncated || hit_cap || rows.size > MAX_ROWS
        }
      end

      private

      def browser_event?(event)
        return false unless event["type"] == CUSTOM

        data = event["data"]
        data.is_a?(Hash) && data["tag"] != ERROR_TAG
      end

      def build_row(summary, window_id, anchor, event)
        data = event["data"] || {}
        ts = event["timestamp"]
        payload = data["payload"]
        {
          name: data["tag"].to_s,
          session_id: summary[:session_id],
          window_id: window_id,
          timestamp: ts,
          offset_ms: offset_ms(anchor, ts),
          payload: payload.is_a?(Hash) ? payload : nil
        }
      end
    end
  end
end
