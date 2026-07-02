# frozen_string_literal: true

require "test_helper"
require "sentiero/web/analytics_app"
require "rack/test"

module Sentiero
  module Web
    # /analytics/frustration page (Plan 21, C2).
    class AnalyticsFrustrationPageTest < Minitest::Test
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

      def click(ts, x, y)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 2, "type" => 2, "x" => x, "y" => y}}
      end

      def mutation(ts)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 0, "adds" => [], "removes" => [], "attributes" => [], "texts" => []}}
      end

      # A session with one rage burst (selector-annotated) and one dead click.
      def seed_frustrated_session(id, url: URL, selector: "button#buy", window_id: "w1")
        events = [
          {"type" => 4, "timestamp" => now_ms, "data" => {"href" => url, "width" => 1280, "height" => 800}},
          mutation(now_ms),
          click(now_ms + 1000, 100, 100),
          click(now_ms + 1100, 100, 100),
          click(now_ms + 1200, 100, 100),
          {"type" => 5, "timestamp" => now_ms + 1000,
           "data" => {"tag" => "__click", "payload" => {"selector" => selector}}},
          mutation(now_ms + 1300),
          click(now_ms + 5000, 300, 300)
        ]
        @store.save_events(Sentiero::WindowRef.new(id, window_id), events)
        @store.save_metadata(id, {"url" => url})
      end

      def test_frustration_returns_200_with_heading
        seed_frustrated_session("f-1")

        get "/analytics/frustration"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Frustration"
        assert_includes last_response.body, "shop.test/checkout"
      end

      def test_frustration_returns_403_when_auth_fails
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/analytics/frustration"

        assert_equal 403, last_response.status
      end

      def test_frustration_sets_security_headers_and_csrf_cookie
        get "/analytics/frustration"

        assert_equal "nosniff", last_response.headers["x-content-type-options"]
        assert_equal "DENY", last_response.headers["x-frame-options"]
        assert last_response.headers["content-security-policy"]
        assert_includes last_response.headers["set-cookie"], "sentiero_csrf="
        assert_includes last_response.headers["set-cookie"], "HttpOnly"
      end

      def test_frustration_renders_rage_and_dead_counts
        seed_frustrated_session("f-1")

        get "/analytics/frustration"

        assert_match(/Rage clicks/i, last_response.body)
        assert_match(/Dead clicks/i, last_response.body)
        assert_match(/Sessions/i, last_response.body)
      end

      def test_frustration_lists_top_rage_clicked_selectors
        seed_frustrated_session("f-1", selector: "button#buy")

        get "/analytics/frustration"

        assert_includes last_response.body, "button#buy"
      end

      def test_frustration_renders_incident_replay_links
        seed_frustrated_session("f-1", window_id: "w3")

        get "/analytics/frustration"

        # The rage burst starts 1000ms after the window's first event.
        assert_includes last_response.body, "/sessions/f-1/windows/w3?t=1000"
        assert_includes last_response.body, "Open in player"
      end

      def test_frustration_shows_empty_state_with_no_data
        get "/analytics/frustration"

        assert_match(/No frustration/i, last_response.body)
      end

      # ── C4: error-coincident dead clicks get a "dead + JS error" badge ──

      # A dead click whose response window contains a JS "error" custom event:
      # the A4 analyzer tags the incident kind "error" (the page crashed
      # instead of responding).
      def seed_error_dead_session(id, url: URL)
        events = [
          {"type" => 4, "timestamp" => now_ms, "data" => {"href" => url, "width" => 1280, "height" => 800}},
          mutation(now_ms),
          click(now_ms + 5000, 300, 300),
          {"type" => 5, "timestamp" => now_ms + 5050,
           "data" => {"tag" => "error", "payload" => {"message" => "boom"}}}
        ]
        @store.save_events(Sentiero::WindowRef.new(id, "w1"), events)
        @store.save_metadata(id, {"url" => url})
      end

      def test_frustration_error_dead_click_badge_links_to_client_errors
        seed_error_dead_session("f-err")

        get "/analytics/frustration"

        body = last_response.body
        assert_includes body, "dead + JS error"
        assert_includes body, 'data-incident-kind="error"'
        assert_includes body, "/issues?source=client"
      end

      def test_frustration_plain_dead_click_keeps_plain_badge
        seed_frustrated_session("f-1")

        get "/analytics/frustration"

        body = last_response.body
        assert_includes body, ">dead</span>"
        refute_includes body, "dead + JS error"
      end

      def test_frustration_escapes_url_html
        seed_frustrated_session("f-xss", url: "https://x.test/<script>alert(1)</script>")

        get "/analytics/frustration"

        refute_includes last_response.body, "<script>alert(1)</script>"
        assert_includes last_response.body, "&lt;script&gt;"
      end

      def test_frustration_escapes_selector_html
        seed_frustrated_session("f-xss", selector: "button.<script>alert(2)</script>")

        get "/analytics/frustration"

        refute_includes last_response.body, "<script>alert(2)</script>"
      end

      def test_frustration_truncation_warning_shown_when_capped
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 1)
        seed_frustrated_session("f-1")
        seed_frustrated_session("f-2")

        get "/analytics/frustration"

        assert_equal 200, last_response.status
        assert_match(/truncat|capp|incomplete/i, last_response.body)
      end

      def test_frustration_renders_from_to_date_inputs
        get "/analytics/frustration"

        assert_includes last_response.body, 'name="since"'
        assert_includes last_response.body, 'name="until"'
      end

      def test_frustration_honors_date_range
        seed_frustrated_session("f-1")
        yesterday = (Time.now.utc.to_date - 1).to_s
        today = Time.now.utc.to_date.to_s

        get "/analytics/frustration?until=#{yesterday}"
        assert_match(/No frustration/i, last_response.body)

        get "/analytics/frustration?since=#{today}&until=#{today}"
        assert_includes last_response.body, "shop.test/checkout"
      end
    end
  end
end
