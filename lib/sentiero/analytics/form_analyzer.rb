# frozen_string_literal: true

require_relative "analyzer"
require_relative "collectors/form_collector"

module Sentiero
  module Analytics
    # Cross-session form analysis built from interaction patterns: rrweb input
    # events (incremental, type 3 / source 5) carry the touched node's id and
    # timing but never values, so this works with maskAllInputs enabled.
    #
    # Attribution is per page: each session's windows are merged, ordered by
    # time, and split into page segments on Meta-href boundaries (the shared
    # Analyzer#each_page_segment mechanism). A (session, page) unit "starts" a
    # form when the segment contains input events, and is "completed" only
    # when a __form_submit custom event — emitted by the recorder's
    # capture-phase document submit listener (config.track_forms) — lands in
    # the same segment at or after the first input. A session counts as
    # completed when EVERY page it interacted on was submitted, so a genuine
    # submit elsewhere (a later todo add) can no longer mask an abandonment
    # (the signup form it walked away from).
    #
    # CAPTURE-VERSION NOTE: submits are counted ONLY from __form_submit
    # events. Windows recorded before that capture existed (or with
    # track_forms off) carry none and intentionally report ZERO submits —
    # falling back to counting bare Meta/navigation events would resurrect
    # the "navigating away counts as submitting" defect (product review
    # P1.4/D4: 100% shown where the funnel proved 50%).
    #
    # Fields are keyed per (page URL, node id) so the same rrweb node id on
    # two different pages (ids reset every full-page load) no longer
    # conflates two unrelated fields. Per field it reports touch rate
    # (fraction of interacting sessions), aggregate time-to-fill, and re-fill
    # frequency, plus a drop-off table (the last field touched in each
    # abandoned page segment).
    #
    # Compute-on-read: a full scan of Store#each_session_events up to the
    # store's limits.analytics_max_scan_sessions — no fact-extraction tables.
    #
    # Per-segment math (input recognition, field accumulation, drop-off,
    # submit detection, and session-level started/completed semantics) lives in
    # FormCollector so PageReportAnalyzer can share it without duplication.
    class FormAnalyzer < Analyzer
      # rrweb EventType.FullSnapshot and NodeType.Element — used to read field
      # identity (name/id/type) from the DOM snapshot for human field labels.
      FULL_SNAPSHOT = 2
      ELEMENT_NODE = 2
      FORM_CONTROL_TAGS = %w[input select textarea].freeze

      # Aggregates form interactions across sessions. Returns per-field stats,
      # the drop-off table, form-level completion rate, the raw submit count,
      # and whether the scan was capped. since/until_time (epoch seconds)
      # bound the scan at the store level.
      def analyze(limit: nil, since: nil, until_time: nil)
        scan_cap = limit || store.limits.analytics_max_scan_sessions
        collector = FormCollector.new  # unbounded: no per-URL field cap here

        sessions = merge_windows(scan_cap, since, until_time)
        sessions.each { |session_id, session| analyze_session(collector, session_id, session) }

        started = collector.started_count
        {
          sessions_with_form_interaction: started,
          sessions_completed: collector.completed_count,
          completion_rate: ratio(collector.completed_count, started),
          total_submits: collector.total_submits,
          fields: collector.summarize_fields(started, include_labels: true),
          drop_off_fields: collector.summarize_drop_off(include_labels: true),
          was_truncated: sessions.size >= scan_cap
        }
      end

      private

      # Each session may span several windows; each_session_events yields once
      # per window. Concatenate a session's windows so it is analyzed once and
      # its cross-window form interactions are seen together.
      def merge_windows(scan_cap, since, until_time)
        sessions = Hash.new { |h, id| h[id] = {events: []} }

        store.each_session_events(limit: scan_cap, since: since, until_time: until_time) do |summary, _window_id, events|
          sessions[summary[:session_id]][:events].concat(events)
        end

        sessions
      end

      # Walks one session's page segments, feeding each to the shared collector.
      # Labels are built per-segment from the DOM snapshot so field identities
      # (name/id/type) survive same-URL reloads correctly.
      def analyze_session(collector, session_id, session)
        events = order_by_time(session[:events])
        each_page_segment(events) do |url, segment, _anchor|
          collector.collect(session_id, url, segment, labels: field_labels(segment))
        end
      end

      # Concatenated windows interleave in time, so order by timestamp to keep
      # segmentation and first-input/submit ordering correct. Events without a
      # numeric timestamp sort to the front so they never count as "after" input.
      def order_by_time(events)
        events.sort_by { |event| event["timestamp"].is_a?(Numeric) ? event["timestamp"] : -Float::INFINITY }
      end

      # Maps node id => human field label from the full DOM snapshots (rrweb
      # type 2) in this page segment. rrweb input events carry only the node id;
      # the snapshot is the only place the field's name/id/type live, and node
      # ids are scoped to a page load, so this is built per segment. Attributes
      # only — never values. Returns {} when the segment has no snapshot
      # (incremental-only windows fall back to nil labels in the output).
      def field_labels(segment)
        segment.each_with_object({}) do |event, labels|
          next unless event["type"] == FULL_SNAPSHOT
          collect_field_labels(event.dig("data", "node"), labels)
        end
      end

      def collect_field_labels(node, labels)
        return unless node.is_a?(Hash)
        if node["type"] == ELEMENT_NODE && FORM_CONTROL_TAGS.include?(node["tagName"])
          id = node["id"]
          labels[id] = field_label(node["attributes"] || {}, node["tagName"]) if id.is_a?(Integer)
        end
        children = node["childNodes"]
        children.each { |child| collect_field_labels(child, labels) } if children.is_a?(Array)
      end

      # Prefer the field's name, then its DOM id, then its type; append the
      # input type for context when a named text-like field exists, and never
      # emit values.
      def field_label(attrs, tag)
        base = present(attrs["name"]) || present(attrs["id"])
        type = present(attrs["type"])
        if base
          (tag == "input" && type) ? "#{base} (#{type})" : base
        elsif tag == "select"
          "select"
        else
          type || tag
        end
      end

      def present(value)
        value if value.is_a?(String) && !value.empty?
      end

      def ratio(numerator, denominator)
        return 0 if denominator.zero?
        numerator.to_f / denominator
      end
    end
  end
end
