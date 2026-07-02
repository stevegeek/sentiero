# frozen_string_literal: true

require_relative "base_view"

module Sentiero
  module Web
    module Views
      class SessionShowView < BaseView
        # Maximum tab buttons shown inline in the window switcher before the rest
        # collapse into the overflow menu.
        MAX_VISIBLE_TABS = 5

        def initialize(session:, session_id:, window_id:, shareable_replays:, server_activity:)
          super()
          @session = session
          @session_id = session_id
          @window_id = window_id
          @shareable_replays = shareable_replays
          @server_activity = server_activity
        end

        attr_reader :session, :session_id, :window_id, :shareable_replays, :server_activity

        def template = "session_show.html.erb"

        def meta = session[:metadata]
        def total_events = session[:windows]&.sum { |w| w[:event_count] } || 0
        def duration_str = format_duration(session[:first_event_at], session[:last_event_at])
        def multi_window? = tabs[:all].size > 1
        def custom_keys = meta.keys - ["url", "referrer", "userAgent", "viewport"]

        # Splits the session's windows into the switcher's inline tab buttons and
        # overflow menu, keeping the active window visible. Windows are sorted by
        # last activity and numbered once into {window:, tab_num:} pairs so the
        # template never re-derives a tab number. Returns {all:, visible:, overflow:}.
        def tabs
          @tabs ||= partition_windows(session[:windows] || [], window_id)
        end

        # Player-relative server-activity markers, lazily so base_path (set after
        # construction by render_page) is available.
        def server_markers
          @server_markers ||= build_server_markers
        end

        private

        def partition_windows(windows, active_window_id, max_visible: MAX_VISIBLE_TABS)
          sorted = windows.sort_by { |w| w[:last_event_at] || 0 }
          tabs = sorted.each_with_index.map { |w, i| {window: w, tab_num: i + 1} }
          return {all: tabs, visible: tabs, overflow: []} if tabs.size <= max_visible

          # Show the first max_visible - 1 tabs (one slot is kept for the
          # "+N more" button), swapping the last visible slot for the active
          # tab when it would otherwise be hidden.
          visible_indices = (0...(max_visible - 1)).to_a
          active_idx = tabs.index { |t| t[:window][:window_id] == active_window_id }
          visible_indices[-1] = active_idx if active_idx && !visible_indices.include?(active_idx)
          visible = visible_indices.sort.map { |i| tabs[i] }
          {all: tabs, visible: visible, overflow: tabs - visible}
        end

        # The player anchors t=0 at the window's first event (epoch MILLISECONDS);
        # server timestamps are float SECONDS, so they are *1000 before subtracting
        # the anchor. Offsets clamp to >= 0 so pre-window items pin at the start.
        def build_server_markers
          return [] if server_activity.nil? || server_activity.empty?

          window = (session[:windows] || []).find { |w| w[:window_id] == window_id }
          anchor_ms = window && window[:first_event_at]
          return [] unless anchor_ms

          server_activity.map { |item|
            offset_ms = ((item[:timestamp] * 1000) - anchor_ms).round
            offset_ms = 0 if offset_ms < 0

            if item[:kind] == "exception"
              occ = item[:occurrence]
              cls = occ["exception_class"].to_s
              msg = occ["message"].to_s
              label = msg.empty? ? cls : "#{cls}: #{msg}"
              {
                offset_ms: offset_ms,
                kind: "exception",
                label: label[0, 120],
                level: "error",
                href: "#{base_path}/issues/#{occ["fingerprint"]}"
              }
            else
              event = item[:event]
              href = event["id"] ? "#{base_path}/custom-events/#{event["id"]}" : nil
              {
                offset_ms: offset_ms,
                kind: "event",
                label: event["name"].to_s[0, 120],
                level: event["level"].to_s,
                href: href
              }
            end
          }.sort_by { |m| m[:offset_ms] }
        end
      end
    end
  end
end
