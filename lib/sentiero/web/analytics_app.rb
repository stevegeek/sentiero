# frozen_string_literal: true

require_relative "base_app"
require_relative "../analytics/stats_aggregator"
require_relative "../analytics/segmenter"
require_relative "../analytics/error_discovery"
require_relative "../analytics/heatmap_analyzer"
require_relative "../analytics/scroll_depth_analyzer"
require_relative "../analytics/form_analyzer"
require_relative "../analytics/exporter"
require_relative "csv_writer"
require_relative "shareable_replay"

module Sentiero
  module Web
    # Rack app owning all /analytics/* routes.
    # Mounted at the same point as DashboardApp (which delegates /analytics requests here),
    # so PATH_INFO/SCRIPT_NAME are read from env to preserve base_path.
    class AnalyticsApp < BaseApp
      def initialize
        super
        BaseApp.warn_unauthenticated_once
      end

      def call(env)
        path = env["PATH_INFO"] || "/"

        return unauthorized_response unless authorized?(env)

        case path
        when "/analytics"
          handle_overview(env)
        when "/analytics/heatmap"
          handle_heatmap(env)
        when "/analytics/heatmap.json"
          handle_heatmap_json(env)
        when "/analytics/segments"
          handle_segments(env)
        when "/analytics/scroll"
          handle_scroll(env)
        when "/analytics/vitals"
          handle_vitals(env)
        when "/analytics/frustration"
          handle_frustration(env)
        when "/analytics/funnel"
          handle_funnel(env)
        when "/analytics/engagement"
          handle_engagement(env)
        when "/analytics/conversions"
          handle_conversions(env)
        when "/analytics/forms"
          handle_forms(env)
        when "/analytics/page"
          handle_page(env)
        when "/analytics/export"
          handle_export_index(env)
        when %r{\A/analytics/export/(\w+)\.(csv|json)\z}
          handle_export_download(env, $1, $2)
        when %r{\A/analytics/share/([^/]+)\z}
          id = $1
          return invalid_id unless valid_id?(id)
          return not_found unless shareable_replays?
          handle_share(env, id)
        when "/analytics/import"
          return not_found unless shareable_replays?
          handle_import(env)
        else
          not_found
        end
      end

      ALLOWED_RANGES = [14, 30, 90].freeze
      DEFAULT_RANGE = 30

      BROWSER_OPTIONS = %w[Chrome Safari Firefox Edge Opera Other].freeze
      DEVICE_OPTIONS = %w[Desktop Mobile Tablet].freeze
      METADATA_MATCH_OPTIONS = %w[exact contains].freeze

      ENGAGEMENT_SORTS = %w[score duration].freeze

      # Cap on free-text filter inputs
      MAX_FILTER_LENGTH = 256

      private

      def shareable_replays?
        Sentiero.configuration.shareable_replays
      end

      def handle_segments(env)
        params = query_params(env)
        filters = parse_segment_filters(params)

        page, per_page, offset = paginate(params, default: 20, max: 100)

        result = Sentiero::Analytics::Segmenter.new(Sentiero.store, **filters.except(:since_param, :until_param))
          .matching(limit: per_page, offset: offset)

        audit!(env, action: :list_sessions)

        render_page(env, Views::SegmentsView.new(
          filters: filters,
          browser_options: BROWSER_OPTIONS,
          device_options: DEVICE_OPTIONS,
          sessions: result[:sessions],
          page: page,
          per_page: per_page,
          has_next: result[:has_next],
          was_truncated: result[:was_truncated],
          filter_query: segment_filter_query(filters)
        ))
      end

      def render_analyzer_page(env, analyzer:, view_class:)
        params = query_params(env)
        since, until_time = parse_range_params(params)
        since_param, until_param = echo_range_params(params, since, until_time)

        result = analyzer.new(Sentiero.store).analyze(since: since, until_time: until_time)

        render_page(env, view_class.new(
          pages: result[:pages],
          was_truncated: result[:was_truncated],
          since: since_param,
          until_str: until_param
        ))
      end

      def handle_scroll(env)
        render_analyzer_page(env,
          analyzer: Sentiero::Analytics::ScrollDepthAnalyzer,
          view_class: Views::ScrollView)
      end

      def handle_forms(env)
        params = query_params(env)
        since, until_time = parse_range_params(params)
        since_param, until_param = echo_range_params(params, since, until_time)

        result = Sentiero::Analytics::FormAnalyzer.new(Sentiero.store)
          .analyze(since: since, until_time: until_time)

        render_page(env, Views::FormsView.new(
          sessions_started: result[:sessions_with_form_interaction],
          sessions_completed: result[:sessions_completed],
          completion_rate: result[:completion_rate],
          total_submits: result[:total_submits],
          fields: result[:fields],
          drop_off_fields: result[:drop_off_fields],
          was_truncated: result[:was_truncated],
          since: since_param,
          until_str: until_param
        ))
      end

      # Per-URL drill-down composing every metric for one selected URL. Read-only
      # aggregate (no session listing), so not audited.
      def handle_page(env)
        require_relative "../analytics/page_report_analyzer"

        params = query_params(env)
        url = clean_text(params["url"])
        since, until_time = parse_range_params(params)
        since_param, until_param = echo_range_params(params, since, until_time)

        urls = Sentiero::Analytics::HeatmapAnalyzer.new(Sentiero.store).recorded_urls.sort

        report = if url
          Sentiero::Analytics::PageReportAnalyzer.new(Sentiero.store)
            .analyze(url, since: since, until_time: until_time)
        end

        render_page(env, Views::PageReportView.new(
          report: report,
          urls: urls,
          selected_url: url,
          was_truncated: report ? report[:was_truncated] : false,
          since: since_param,
          until_str: until_param
        ))
      end

      def handle_heatmap(env)
        params = query_params(env)
        selected_url = clean_text(params["url"])
        since, until_time = parse_range_params(params)
        since_param, until_param = echo_range_params(params, since, until_time)

        analyzer = Sentiero::Analytics::HeatmapAnalyzer.new(Sentiero.store)
        # The picker lists every recorded page (not just in-range ones) so a
        # range tweak never empties the dropdown.
        urls = analyzer.recorded_urls.sort
        selected_url ||= urls.first

        # Only run the (expensive) per-event scan when a URL is selected. This
        # scan exists only to render the truncation banner; heatmap.json scans
        # again for the grid data (deduplicating is a deferred optimization).
        was_truncated = selected_url ? analyzer.analyze(selected_url, since: since, until_time: until_time)[:was_truncated] : false

        base_path = base_path(env)
        config = JSON.generate({
          jsonUrl: heatmap_json_url(base_path, since_param, until_param),
          eventsUrlTemplate: "#{base_path}/api/sessions/{session}/windows/{window}/events",
          selectedUrl: selected_url
        })

        render_page(env, Views::HeatmapView.new(
          urls: urls,
          selected_url: selected_url,
          was_truncated: was_truncated,
          config_json: config,
          since: since_param,
          until_str: until_param
        ))
      end

      def heatmap_json_url(base_path, since_param, until_param)
        url = "#{base_path}/analytics/heatmap.json"
        range = {"since" => since_param, "until" => until_param}.reject { |_key, value| value.empty? }
        range.empty? ? url : "#{url}?#{Rack::Utils.build_query(range)}"
      end

      # Read-only JSON API for the heatmap canvas. The bucket grid is keyed by
      # [col, row] tuples server-side; it is emitted as a flat list of
      # {x, y, count} so it round-trips through JSON.
      def handle_heatmap_json(env)
        params = query_params(env)
        url = clean_text(params["url"])
        since, until_time = parse_range_params(params)

        result = if url
          Sentiero::Analytics::HeatmapAnalyzer.new(Sentiero.store).analyze(url, since: since, until_time: until_time)
        else
          {clicks_by_bucket: {}, top_elements: [], total_clicks: 0, representative_window: nil, was_truncated: false}
        end

        payload = {
          grid_size: Sentiero::Analytics::HeatmapAnalyzer::GRID_SIZE,
          total_clicks: result[:total_clicks],
          clicks_by_bucket: result[:clicks_by_bucket].map { |(x, y), count| {x: x, y: y, count: count} },
          top_elements: result[:top_elements],
          representative_window: result[:representative_window],
          was_truncated: result[:was_truncated]
        }

        [200, json_headers, [JSON.generate(payload)]]
      end

      def handle_export_index(env)
        params = query_params(env)
        since, until_time = parse_range_params(params)
        since_param, until_param = echo_range_params(params, since, until_time)

        render_page(env, Views::ExportView.new(
          shareable_replays: shareable_replays?,
          since: since_param,
          until_str: until_param,
          datasets: Sentiero::Analytics::Exporter::DATASETS
        ))
      end

      # Downloads are POST + CSRF-guarded.
      def handle_export_download(env, dataset, format)
        return [405, {"content-type" => "text/plain"}, ["Method Not Allowed"]] unless env["REQUEST_METHOD"] == "POST"

        post_params = Rack::Request.new(env).POST
        return forbidden_csrf unless valid_csrf_token?(env, post_params["csrf_token"])

        exporter = Sentiero::Analytics::Exporter.new(Sentiero.store)
        return not_found unless exporter.dataset?(dataset)

        audit!(env, action: :export, dataset: dataset)

        since, until_time = parse_range_params(post_params)
        table = exporter.table(dataset, since: since, until_time: until_time)
        body, content_type = render_export(table, format)
        filename = "#{dataset}#{range_filename_suffix(since, until_time)}.#{format}"
        [200, download_headers(content_type, filename), [body]]
      end

      def range_filename_suffix(since, until_time)
        return "" unless since || until_time

        from = since ? Time.at(since).utc.strftime("%Y-%m-%d") : "start"
        to = until_time ? Time.at(until_time).utc.strftime("%Y-%m-%d") : "now"
        "_#{from}_to_#{to}"
      end

      def render_export(table, format)
        if format == "csv"
          [CsvWriter.generate(table[:headers], table[:rows]), "text/csv"]
        else
          [JSON.generate(table), "application/json"]
        end
      end

      def handle_share(env, id)
        html = ShareableReplay.new(Sentiero.store, id).html
        return not_found if html.nil?

        audit!(env, action: :share, session_id: id)

        [200, download_headers("text/html", "session-#{sanitize_filename(id)}.html"), [html]]
      end

      def sanitize_filename(id)
        id.gsub(/[^a-zA-Z0-9_-]/, "")
      end

      def download_headers(content_type, filename)
        {
          "content-type" => content_type,
          "content-disposition" => "attachment; filename=\"#{filename}\"",
          "x-content-type-options" => "nosniff"
        }
      end

      def parse_segment_filters(params)
        since = parse_since_param(params["since"])
        until_time = parse_until_param(params["until"])

        {
          browser: allowed(params["browser"], BROWSER_OPTIONS),
          device: allowed(params["device"], DEVICE_OPTIONS),
          url_pattern: clean_text(params["url_pattern"]),
          metadata_key: clean_text(params["metadata_key"]),
          metadata_value: clean_text(params["metadata_value"]),
          metadata_match: allowed(params["metadata_match"], METADATA_MATCH_OPTIONS) || "exact",
          has_errors: params["has_errors"] == "true",
          min_duration_ms: parse_duration_seconds(params["min_duration"]),
          max_duration_ms: parse_duration_seconds(params["max_duration"]),
          since: since,
          until_time: until_time,
          # Raw strings, echoed back to the form/pagination only when they
          # parsed successfully (so garbage input is dropped, not round-tripped).
          since_param: since ? clean_text(params["since"]) : nil,
          until_param: until_time ? clean_text(params["until"]) : nil
        }
      end

      def segment_filter_query(filters)
        query = {
          "browser" => filters[:browser],
          "device" => filters[:device],
          "url_pattern" => filters[:url_pattern],
          "metadata_key" => filters[:metadata_key],
          "metadata_value" => filters[:metadata_value],
          "metadata_match" => filters[:metadata_match],
          "min_duration" => filters[:min_duration_ms]&.then { |ms| ms / 1000 },
          "max_duration" => filters[:max_duration_ms]&.then { |ms| ms / 1000 },
          "since" => filters[:since_param],
          "until" => filters[:until_param]
        }.compact
        query["has_errors"] = "true" if filters[:has_errors]
        Rack::Utils.build_query(query)
      end

      def allowed(value, options)
        options.include?(value) ? value : nil
      end

      def clean_text(value)
        return nil unless value.is_a?(String)
        stripped = value.strip
        return nil if stripped.empty?
        stripped[0, MAX_FILTER_LENGTH]
      end

      # The form takes durations in whole seconds; the Segmenter works in ms.
      def parse_duration_seconds(value)
        return nil unless value.is_a?(String) && value.match?(/\A\d+\z/)
        value.to_i * 1000
      end

      def handle_overview(env)
        params = query_params(env)
        range_days = parse_range(params["range"])
        # Custom since/until bounds take precedence over the ?range=N preset
        # (which stays supported as an alias / quick-fill).
        since, until_time = parse_range_params(params)

        aggregator = Sentiero::Analytics::StatsAggregator.new(Sentiero.store)
        # One widened scan yields both the current window (carrying the bounded
        # server-exception overlay) and the equal-length prior window for deltas.
        combined = aggregator.aggregate_with_prior(range_days: range_days, since: since, until_time: until_time)
        stats = combined[:current]

        render_page(env, Views::AnalyticsIndexView.new(
          range_days: range_days,
          allowed_ranges: ALLOWED_RANGES,
          custom_range: !(since.nil? && until_time.nil?),
          since: since ? params["since"].to_s : "",
          until_str: until_time ? params["until"].to_s : "",
          deltas: overview_deltas(stats, combined[:prior]),
          stats: stats
        ))
      end

      def parse_range(value)
        range = value.to_i
        ALLOWED_RANGES.include?(range) ? range : DEFAULT_RANGE
      end

      # Deltas against the prior (equal-length, immediately preceding) window.
      # Skipped when the prior aggregate is absent (zero-length window or a
      # truncated scan) or when either window's scan was truncated.
      def overview_deltas(stats, prior)
        return nil if stats[:was_truncated]
        return nil if prior.nil? || prior[:was_truncated]

        {
          sessions: percent_delta(stats[:total_sessions], prior[:total_sessions]),
          events: percent_delta(stats[:total_events], prior[:total_events]),
          error_free_rate: error_free_rate_delta(stats, prior)
        }
      end

      def percent_delta(current, prior)
        return nil if prior.nil? || prior.zero?
        ((current - prior).to_f / prior * 100).round(1)
      end

      def error_free_rate_delta(stats, prior)
        current_rate = error_free_rate(stats)
        prior_rate = error_free_rate(prior)
        return nil unless current_rate && prior_rate
        (current_rate - prior_rate).round(1)
      end

      def error_free_rate(stats)
        total = stats[:total_sessions]
        return nil if total.zero?
        (1 - stats[:sessions_with_errors].to_f / total) * 100
      end

      def handle_vitals(env)
        require_relative "../analytics/web_vitals_analyzer"

        render_analyzer_page(env,
          analyzer: Sentiero::Analytics::WebVitalsAnalyzer,
          view_class: Views::VitalsView)
      end

      def handle_frustration(env)
        require_relative "../analytics/frustration_analyzer"

        render_analyzer_page(env,
          analyzer: Sentiero::Analytics::FrustrationAnalyzer,
          view_class: Views::FrustrationView)
      end

      FUNNEL_STEP_PARAMS = %w[step1 step2 step3].freeze

      def handle_funnel(env)
        require_relative "../analytics/funnel_analyzer"

        params = query_params(env)
        since, until_time = parse_range_params(params)
        since_param, until_param = echo_range_params(params, since, until_time)

        requested = FUNNEL_STEP_PARAMS.filter_map { |key| clean_text(params[key]) }
        steps = Sentiero::Analytics::FunnelAnalyzer.usable_steps(requested)

        result = Sentiero::Analytics::FunnelAnalyzer.new(Sentiero.store)
          .analyze(steps, since: since, until_time: until_time)

        render_page(env, Views::FunnelView.new(
          # Selected steps stay choosable even when out of the scanned range.
          tags: (result[:tags] + steps).uniq.sort,
          selected_steps: steps,
          steps: result[:steps],
          was_truncated: result[:was_truncated],
          since: since_param,
          until_str: until_param
        ))
      end

      def handle_conversions(env)
        require_relative "../analytics/conversion_analyzer"

        params = query_params(env)
        since, until_time = parse_range_params(params)
        since_param, until_param = echo_range_params(params, since, until_time)

        requested = clean_text(params["tag"])
        tag = Sentiero::Analytics::FunnelAnalyzer.usable_steps([requested].compact).first

        result = Sentiero::Analytics::ConversionAnalyzer.new(Sentiero.store)
          .analyze(tag, since: since, until_time: until_time)

        render_page(env, Views::ConversionsView.new(
          # The selected tag stays choosable even when out of the scanned range.
          tags: (result[:tags] + [tag].compact).uniq.sort,
          selected_tag: tag,
          entry_pages: result[:entry_pages],
          referrers: result[:referrers],
          utm: result[:utm],
          was_truncated: result[:was_truncated],
          since: since_param,
          until_str: until_param
        ))
      end

      # Per-session struggle score ranking. Surfaces individual sessions, so audited.
      def handle_engagement(env)
        require_relative "../analytics/engagement_analyzer"

        params = query_params(env)
        since, until_time = parse_range_params(params)
        since_param, until_param = echo_range_params(params, since, until_time)

        # Closed allow-list: anything off it (including bogus values) becomes
        # "score" and is never echoed back into the page.
        sort = ENGAGEMENT_SORTS.include?(params["sort"]) ? params["sort"] : "score"

        result = Sentiero::Analytics::EngagementAnalyzer.new(Sentiero.store)
          .analyze(since: since, until_time: until_time)

        audit!(env, action: :list_sessions)

        render_page(env, Views::EngagementView.new(
          sessions: result[:sessions],
          distribution: result[:distribution],
          scanned: result[:scanned],
          was_truncated: result[:was_truncated],
          sort: sort,
          since: since_param,
          until_str: until_param
        ))
      end

      # Client-side replay page; the replay runs in the browser, so this only renders.
      def handle_import(env)
        render_page(env, Views::ImportView.new)
      end
    end
  end
end
