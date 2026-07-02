# frozen_string_literal: true

require "test_helper"
require "sentiero/web/analytics_app"
require "rack/test"

module Sentiero
  module Web
    # /analytics/vitals page + the web_vitals export dataset (Plan 21, C1).
    class AnalyticsVitalsPageTest < Minitest::Test
      include Rack::Test::Methods

      URL = "https://shop.test/checkout"

      def app
        AnalyticsApp.new
      end

      def setup
        @store = Stores::Memory.new
        Sentiero.configure do |c|
          c.allow_insecure_dashboard = true
          c.store = @store
          c.auth_callback = nil
          c.analytics_max_scan_sessions = 5000
        end
        Manifest.reset!
      end

      def teardown
        Sentiero.reset_configuration!
      end

      def now_ms
        @now_ms ||= (Time.now.to_f * 1000).round
      end

      def seed_vitals_session(id, url: URL, perfs: [["LCP", 2400.0, "good"]], window_id: "w1")
        events = [{"type" => 4, "timestamp" => now_ms, "data" => {"href" => url, "width" => 1280, "height" => 800}}]
        perfs.each_with_index do |(metric, value, rating), i|
          events << {"type" => 5, "timestamp" => now_ms + (i + 1) * 100,
                     "data" => {"tag" => "__perf",
                                "payload" => {"metric" => metric, "value" => value, "rating" => rating}}}
        end
        @store.save_events(Sentiero::WindowRef.new(id, window_id), events)
        @store.save_metadata(id, {"url" => url})
      end

      # ── page ──

      def test_vitals_returns_200_with_heading
        seed_vitals_session("v-1")

        get "/analytics/vitals"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Web Vitals"
        assert_includes last_response.body, "shop.test/checkout"
      end

      def test_vitals_links_to_page_report
        seed_vitals_session("v-1")

        get "/analytics/vitals"

        assert_includes last_response.body, "/analytics/page?url="
        assert_match(/Page report/i, last_response.body)
      end

      def test_vitals_returns_403_when_auth_fails
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/analytics/vitals"

        assert_equal 403, last_response.status
      end

      def test_vitals_sets_security_headers_and_csrf_cookie
        get "/analytics/vitals"

        assert_equal "nosniff", last_response.headers["x-content-type-options"]
        assert_equal "DENY", last_response.headers["x-frame-options"]
        assert last_response.headers["content-security-policy"]
        assert_includes last_response.headers["set-cookie"], "sentiero_csrf="
        assert_includes last_response.headers["set-cookie"], "HttpOnly"
      end

      def test_vitals_renders_per_metric_p75_columns
        seed_vitals_session("v-1", perfs: [["LCP", 2400.0, "good"], ["INP", 350.0, "needs-improvement"], ["CLS", 0.25, "poor"]])

        get "/analytics/vitals"

        assert_includes last_response.body, "LCP"
        assert_includes last_response.body, "INP"
        assert_includes last_response.body, "CLS"
        # LCP/INP p75 render as whole milliseconds; CLS is unitless, 3 decimals.
        assert_includes last_response.body, "2400 ms"
        assert_includes last_response.body, "350 ms"
        assert_includes last_response.body, "0.250"
      end

      def test_vitals_renders_per_metric_sample_counts_and_no_reports_marker
        seed_vitals_session("v-1", perfs: [["LCP", 2400.0, "good"]])
        seed_vitals_session("v-2", perfs: [["LCP", 1800.0, "good"]])

        get "/analytics/vitals"

        # Per-metric n= instead of one cross-metric "Samples" sum (A5);
        # never-reported metrics say so instead of a bare dash.
        assert_includes last_response.body, "n=2"
        assert_includes last_response.body, "(no reports)"
        refute_includes last_response.body, ">Samples<"
      end

      def test_vitals_collapses_candidates_to_one_sample_per_page_view
        # Multiple LCP reports in one continuous page view are candidates of
        # the same measurement — the page must show the final value, n=1.
        seed_vitals_session("v-1", perfs: [["LCP", 9000.0, "poor"], ["LCP", 2400.0, "good"]])

        get "/analytics/vitals"

        assert_includes last_response.body, "2400 ms"
        assert_includes last_response.body, "n=1"
        refute_includes last_response.body, "9000 ms"
      end

      def test_vitals_renders_slowest_session_replay_link
        seed_vitals_session("v-slow", window_id: "w9", perfs: [["LCP", 8200.0, "poor"]])

        get "/analytics/vitals"

        # The worst LCP sample sits 100ms after its window's first event.
        assert_includes last_response.body, "/sessions/v-slow/windows/w9?t=100"
      end

      def test_vitals_shows_empty_state_with_no_data
        get "/analytics/vitals"

        assert_match(/No Web Vitals/i, last_response.body)
      end

      def test_vitals_escapes_url_html
        seed_vitals_session("v-xss", url: "https://x.test/<script>alert(1)</script>")

        get "/analytics/vitals"

        refute_includes last_response.body, "<script>alert(1)</script>"
        assert_includes last_response.body, "&lt;script&gt;"
      end

      def test_vitals_truncation_warning_shown_when_capped
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 1)
        seed_vitals_session("v-1")
        seed_vitals_session("v-2")

        get "/analytics/vitals"

        assert_equal 200, last_response.status
        assert_match(/truncat|capp|incomplete/i, last_response.body)
      end

      def test_vitals_renders_from_to_date_inputs
        get "/analytics/vitals"

        assert_includes last_response.body, 'name="since"'
        assert_includes last_response.body, 'name="until"'
      end

      def test_vitals_honors_date_range
        seed_vitals_session("v-1")
        yesterday = (Time.now.utc.to_date - 1).to_s
        today = Time.now.utc.to_date.to_s

        get "/analytics/vitals?until=#{yesterday}"
        assert_match(/No Web Vitals/i, last_response.body)

        get "/analytics/vitals?since=#{today}&until=#{today}"
        assert_includes last_response.body, "shop.test/checkout"
      end

      # ── export dataset ──

      def csrf_token_from_index
        get "/analytics/export"
        last_response.headers["set-cookie"][/sentiero_csrf=([^;]+)/, 1]
      end

      def download(type, format, params = {})
        token = csrf_token_from_index
        post "/analytics/export/#{type}.#{format}", params.merge("csrf_token" => token)
      end

      def test_export_index_lists_web_vitals_dataset
        get "/analytics/export"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Web Vitals"
        assert_includes last_response.body, "/analytics/export/web_vitals.csv"
      end

      def test_web_vitals_csv_download_lists_per_metric_rows
        seed_vitals_session("v-1", perfs: [["LCP", 2400.0, "good"], ["CLS", 0.05, "good"]])

        download("web_vitals", "csv")

        assert_equal 200, last_response.status
        assert_equal "text/csv", last_response.headers["content-type"]
        assert_includes last_response.headers["content-disposition"], "web_vitals.csv"
        assert_includes last_response.body, "url,metric,p50,p75,p90,samples,good_count,needs_improvement_count,poor_count"
        assert_includes last_response.body, URL
        assert_includes last_response.body, "LCP"
        assert_includes last_response.body, "CLS"
      end

      def test_web_vitals_json_download_returns_table
        seed_vitals_session("v-1")

        download("web_vitals", "json")

        assert_equal 200, last_response.status
        data = JSON.parse(last_response.body)
        row = data["rows"].find { |r| r[1] == "LCP" }
        assert row, "expected an LCP row"
        assert_equal URL, row[0]
        assert_equal 1, row[5] # samples
        assert_equal 1, row[6] # good_count
        assert_equal 0, row[8] # poor_count
      end

      def test_web_vitals_export_requires_csrf_token
        post "/analytics/export/web_vitals.csv"

        assert_equal 403, last_response.status
      end

      def test_web_vitals_export_honors_date_range
        seed_vitals_session("v-1")
        yesterday = (Time.now.utc.to_date - 1).to_s
        today = Time.now.utc.to_date.to_s

        download("web_vitals", "csv", "since" => yesterday, "until" => yesterday)
        refute_includes last_response.body, URL

        download("web_vitals", "csv", "since" => today, "until" => today)
        assert_includes last_response.body, URL
      end
    end
  end
end
