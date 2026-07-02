# frozen_string_literal: true

require_relative "analyzer"
require_relative "stats_aggregator"
require_relative "error_discovery"
require_relative "heatmap_analyzer"
require_relative "scroll_depth_analyzer"
require_relative "form_analyzer"
require_relative "web_vitals_analyzer"
require_relative "../user_agent"

module Sentiero
  module Analytics
    # Builds tabular datasets for CSV/JSON export. Each dataset is a
    # {headers:, rows:} table the web layer serializes without re-deriving.
    class Exporter < Analyzer
      DATASETS = {
        "sessions" => "Session list",
        "errors" => "Error list",
        "browser_events" => "Browser Events (rrweb)",
        "problems" => "Problems",
        "server_events" => "Server Events",
        "stats" => "Aggregate stats",
        "heatmap" => "Heatmap data",
        "scroll" => "Scroll-depth data",
        "forms" => "Form analytics",
        "web_vitals" => "Web Vitals"
      }.freeze

      def dataset?(name)
        DATASETS.key?(name)
      end

      def table(name, since: nil, until_time: nil)
        @since = since
        @until_time = until_time
        send("build_#{name}")
      end

      private

      attr_reader :since, :until_time

      def scan_cap
        store.limits.analytics_max_scan_sessions
      end

      def build_sessions
        headers = %w[session_id created_at first_event_at last_event_at
          duration_ms event_count url referrer browser device has_errors]

        rows = store.list_sessions(limit: scan_cap, since: since, until_time: until_time).map do |summary|
          metadata = summary[:metadata] || {}
          user_agent = metadata["userAgent"]
          [
            summary[:session_id],
            summary[:created_at],
            summary[:first_event_at],
            summary[:last_event_at],
            duration_ms(summary),
            summary[:event_count],
            metadata["url"],
            metadata["referrer"],
            UserAgent.browser(user_agent),
            UserAgent.device(user_agent),
            metadata["has_errors"] == true
          ]
        end

        {headers: headers, rows: rows}
      end

      def build_errors
        headers = %w[message source line count last_seen_at session_id window_id offset_ms]

        rows = ErrorDiscovery.new(store).grouped_errors(since: since, until_time: until_time)[:groups].flat_map do |group|
          group[:occurrences].map do |occ|
            [
              group[:message],
              group[:source],
              group[:line],
              group[:count],
              group[:last_seen_at],
              occ[:session_id],
              occ[:window_id],
              occ[:offset_ms]
            ]
          end
        end

        {headers: headers, rows: rows}
      end

      def build_browser_events
        headers = %w[session_id window_id timestamp tag]
        rows = []

        store.each_session_events(limit: scan_cap, since: since, until_time: until_time) do |summary, window_id, events|
          events.each do |event|
            next unless event["type"] == CUSTOM
            tag = event.dig("data", "tag")
            rows << [summary[:session_id], window_id, event["timestamp"], tag]
          end
        end

        {headers: headers, rows: rows}
      end

      def build_problems
        headers = %w[id fingerprint project exception_class title count status first_seen last_seen]

        rows = store.list_problems(project: nil, limit: scan_cap, since: since, until_time: until_time).map do |problem|
          [
            problem[:id],
            # A problem's id is its fingerprint; stores don't expose a separate key.
            problem[:id],
            problem[:project],
            problem[:exception_class],
            problem[:title],
            problem[:count],
            problem[:status],
            problem[:first_seen],
            problem[:last_seen]
          ]
        end

        {headers: headers, rows: rows}
      end

      def build_server_events
        headers = %w[id project name level session_id timestamp payload]

        # list_server_events' `after` is an exclusive cursor; filter the range
        # ourselves so `since`/`until` are both inclusive, like every other dataset.
        events = store.list_server_events(project: nil, limit: scan_cap)
        events = events.select { |event| event["timestamp"].to_f >= since } if since
        events = events.select { |event| event["timestamp"].to_f <= until_time } if until_time

        rows = events.map do |event|
          [
            event["id"],
            event["project"],
            event["name"],
            event["level"],
            event["session_id"],
            event["timestamp"],
            event["payload"].is_a?(Hash) ? event["payload"].to_json : event["payload"].to_s
          ]
        end

        {headers: headers, rows: rows}
      end

      def build_stats
        stats = StatsAggregator.new(store).aggregate(since: since, until_time: until_time)

        headers = %w[metric value]
        rows = [
          ["total_sessions", stats[:total_sessions]],
          ["total_events", stats[:total_events]],
          ["avg_duration_ms", stats[:avg_duration_ms]]
        ]
        stats[:browser_distribution].each { |browser, count| rows << ["browser:#{browser}", count] }
        stats[:device_distribution].each { |device, count| rows << ["device:#{device}", count] }
        stats[:custom_event_tags].each { |tag, count| rows << ["custom_event:#{tag}", count] }

        {headers: headers, rows: rows}
      end

      def build_heatmap
        headers = %w[url selector count]
        rows = HeatmapAnalyzer.new(store).build_heatmap_table(since: since, until_time: until_time).flat_map do |url, elements|
          elements.map { |element| [url, element[:selector], element[:count]] }
        end

        {headers: headers, rows: rows}
      end

      def build_scroll
        # Percentages are absolute depth vs. estimated page height (deepest
        # scroll + viewport across sessions).
        headers = %w[url session_count avg_depth_px avg_depth_pct page_height_px p50_pct p75_pct p90_pct]

        rows = ScrollDepthAnalyzer.new(store).analyze(since: since, until_time: until_time)[:pages].map do |url, page|
          folds = page[:fold_lines]
          [
            url,
            page[:session_count],
            page[:avg_depth_px],
            page[:avg_depth_pct],
            page[:page_height_px],
            folds[:p50],
            folds[:p75],
            folds[:p90]
          ]
        end

        {headers: headers, rows: rows}
      end

      def build_web_vitals
        headers = %w[url metric p50 p75 p90 samples good_count needs_improvement_count poor_count]

        pages = WebVitalsAnalyzer.new(store).analyze(since: since, until_time: until_time)[:pages]
        rows = pages.sort_by { |url, _page| url }.flat_map do |url, page|
          page[:metrics].map do |metric, m|
            ratings = m[:ratings]
            [
              url,
              metric,
              m[:p50],
              m[:p75],
              m[:p90],
              m[:samples],
              ratings.fetch("good", 0),
              ratings.fetch("needs-improvement", 0),
              ratings.fetch("poor", 0)
            ]
          end
        end

        {headers: headers, rows: rows}
      end

      def build_forms
        headers = %w[field_id sessions completion_rate avg_time_to_fill_ms total_refills]

        rows = FormAnalyzer.new(store).analyze(since: since, until_time: until_time)[:fields].map do |field|
          [
            field[:field_id],
            field[:sessions],
            field[:completion_rate],
            field[:avg_time_to_fill_ms],
            field[:total_refills]
          ]
        end

        {headers: headers, rows: rows}
      end
    end
  end
end
