# frozen_string_literal: true

require_relative "../events"

module Sentiero
  module Analytics
    module Frustration
      # Pure, self-contained frustration detectors — Ruby ports of the JS
      # detectors (frontend/src/dashboard/frustration.js), pinned by ported
      # tests so the two can't drift. FrustrationAnalyzer layers cross-session
      # aggregation and de-noising on top of this raw detector output.
      module Detectors
        # Detector thresholds — verbatim from frontend/src/dashboard/frustration.js.
        RAGE_WINDOW_MS = 500          # max span of a rage cluster
        RAGE_COORD_TOLERANCE_PX = 10  # max px from the first click
        RAGE_MIN_CLICKS = 3           # min clicks to count as rage
        DEAD_WINDOW_MS = 500          # response deadline for a dead click

        MOUSE_CLICK = 2     # rrweb MouseInteraction click subtype
        SOURCE_MUTATION = 0 # rrweb IncrementalSource.Mutation

        module_function

        def detect_rage_clicks(events)
          return [] unless events.is_a?(Array)

          clicks = events.select { |event| click?(event) }
          return [] if clicks.size < RAGE_MIN_CLICKS

          out = []
          cluster_start = 0
          (1..clicks.size).each do |i|
            prev = clicks[i - 1]
            cur = clicks[i]
            anchor = clicks[cluster_start]
            continues = cur &&
              cur["timestamp"] - prev["timestamp"] <= RAGE_WINDOW_MS &&
              cur["timestamp"] - anchor["timestamp"] <= RAGE_WINDOW_MS &&
              (cur["data"]["x"] - anchor["data"]["x"]).abs <= RAGE_COORD_TOLERANCE_PX &&
              (cur["data"]["y"] - anchor["data"]["y"]).abs <= RAGE_COORD_TOLERANCE_PX

            next if continues

            count = i - cluster_start
            if count >= RAGE_MIN_CLICKS
              out << {
                subtype: "rage_click",
                timestamp: anchor["timestamp"],
                count: count,
                x: anchor["data"]["x"],
                y: anchor["data"]["y"],
                member_timestamps: clicks[cluster_start...i].map { |c| c["timestamp"] },
                event: anchor
              }
            end
            cluster_start = i
          end
          out
        end

        # Clicks with no page response within DEAD_WINDOW_MS.
        def detect_dead_clicks(events)
          return [] unless events.is_a?(Array)

          out = []
          events.each_with_index do |event, i|
            next unless click?(event)
            click_ts = event["timestamp"]
            deadline = click_ts + DEAD_WINDOW_MS

            responded = false
            (i + 1...events.size).each do |j|
              ts = events[j].is_a?(Hash) ? events[j]["timestamp"] : nil
              next unless ts.is_a?(Numeric)
              break if ts > deadline
              if ts > click_ts && response?(events[j])
                responded = true
                break
              end
            end

            unless responded
              out << {
                subtype: "dead_click",
                timestamp: click_ts,
                x: event["data"]["x"],
                y: event["data"]["y"],
                elapsed: DEAD_WINDOW_MS,
                event: event
              }
            end
          end
          out
        end

        # Combines both detectors (clicks absorbed into a rage cluster are not
        # also reported as dead), sorted by offset from the window's first event.
        def detect_frustration_events(events)
          return [] unless events.is_a?(Array) && !events.empty?
          first = events.first
          return [] unless first.is_a?(Hash) && first["timestamp"].is_a?(Numeric)
          first_ts = first["timestamp"]

          rage = detect_rage_clicks(events)
          dead = detect_dead_clicks(events)

          rage_timestamps = {}
          rage.each do |r|
            (r[:member_timestamps] || [r[:timestamp]]).each { |t| rage_timestamps[t] = true }
          end

          combined = rage + dead.reject { |d| rage_timestamps[d[:timestamp]] }

          combined
            .map do |entry|
              {
                category: "frustration",
                subtype: entry[:subtype],
                timestamp: entry[:timestamp],
                offset: entry[:timestamp] - first_ts,
                count: entry[:count],
                elapsed: entry[:elapsed],
                x: entry[:x],
                y: entry[:y],
                event: entry[:event]
              }
            end
            .each_with_index.sort_by { |entry, i| [entry[:offset], i] }
            .map { |entry, _i| entry }
        end

        # rrweb left-click mouse-interaction carrying coordinates (mirrors JS isClick).
        def click?(event)
          return false unless event.is_a?(Hash)
          return false unless event["type"] == Events::INCREMENTAL
          return false unless event["timestamp"].is_a?(Numeric)
          data = event["data"]
          data.is_a?(Hash) &&
            data["source"] == Events::SOURCE_MOUSE_INTERACTION &&
            data["type"] == MOUSE_CLICK &&
            data["x"].is_a?(Numeric) &&
            data["y"].is_a?(Numeric)
        end

        # Page responded to a click: DOM mutation, input change, or meta/navigation
        # (mirrors JS isResponse).
        def response?(event)
          return false unless event.is_a?(Hash) && event["data"]
          return true if event["type"] == Events::META
          return false unless event["type"] == Events::INCREMENTAL
          data = event["data"]
          return false unless data.is_a?(Hash)
          data["source"] == SOURCE_MUTATION || data["source"] == Events::SOURCE_INPUT
        end
      end
    end
  end
end
