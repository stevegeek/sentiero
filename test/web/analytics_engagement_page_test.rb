# frozen_string_literal: true

require "test_helper"
require "sentiero/web/analytics_app"
require "rack/test"

module Sentiero
  module Web
    # /analytics/engagement page (Plan 24, Task 3).
    class AnalyticsEngagementPageTest < Minitest::Test
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

      def meta(ts, href)
        {"type" => 4, "timestamp" => ts, "data" => {"href" => href, "width" => 1024, "height" => 768}}
      end

      # A high-struggle session: a 3-click rage burst at the same coords within
      # 500ms, anchored by a Meta href entry URL.
      def seed_struggle_session(id, url: URL, window_id: "w1")
        events = [
          meta(now_ms, url),
          click(now_ms + 1000, 100, 100),
          click(now_ms + 1100, 100, 100),
          click(now_ms + 1200, 100, 100),
          click(now_ms + 5000, 300, 300)
        ]
        @store.save_events(Sentiero::WindowRef.new(id, window_id), events)
        @store.save_metadata(id, {"url" => url})
      end

      # A higher-struggle session whose composite crosses into badge-warning
      # (score in 30..59). It saturates two signals in one session: THREE
      # separate rage clusters (3 same-coord clicks each, >500ms apart so they
      # stay distinct → rage sub-score 1.0 = 20 pts) PLUS THREE isolated dead
      # clicks (no response within the detector window, >500ms and >10px apart
      # so they neither merge into rage nor count as responsive → dead
      # sub-score 1.0 = 15 pts). The idle gaps between bursts push it further;
      # the composite lands at 41 (well clear of both the 30 and 60 edges).
      def seed_high_struggle_session(id, url: URL, window_id: "w1")
        events = [meta(now_ms, url)]
        [[100, 100], [400, 400], [700, 200]].each_with_index do |(x, y), i|
          base = now_ms + 1000 + i * 2000
          events << click(base, x, y)
          events << click(base + 100, x, y)
          events << click(base + 200, x, y)
        end
        [[50, 500], [60, 600], [70, 700]].each_with_index do |(x, y), i|
          events << click(now_ms + 20_000 + i * 2000, x, y)
        end
        @store.save_events(Sentiero::WindowRef.new(id, window_id), events)
        @store.save_metadata(id, {"url" => url})
      end

      # A calm session: one Meta, a single click, generous duration.
      def seed_clean_session(id, url: "https://shop.test/home")
        events = [
          meta(now_ms, url),
          click(now_ms + 30_000, 50, 50),
          meta(now_ms + 60_000, url)
        ]
        @store.save_events(Sentiero::WindowRef.new(id, "w1"), events)
        @store.save_metadata(id, {"url" => url})
      end

      def test_engagement_returns_200_with_heading
        seed_struggle_session("e-1")

        get "/analytics/engagement"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Engagement"
        assert_includes last_response.body, "shop.test/checkout"
      end

      def test_engagement_returns_403_when_auth_fails
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/analytics/engagement"

        assert_equal 403, last_response.status
      end

      def test_engagement_sets_security_headers_and_csrf_cookie
        get "/analytics/engagement"

        assert_equal "nosniff", last_response.headers["x-content-type-options"]
        assert_equal "DENY", last_response.headers["x-frame-options"]
        assert last_response.headers["content-security-policy"]
        assert_includes last_response.headers["set-cookie"], "sentiero_csrf="
        assert_includes last_response.headers["set-cookie"], "HttpOnly"
      end

      def test_engagement_renders_score_and_distribution
        seed_struggle_session("e-1")

        get "/analytics/engagement"

        # A struggle-score value is rendered in the score column (rage burst
        # produces a positive score).
        assert_match(/class="tabular-nums"><span[^>]*>\s*\d+\s*</, last_response.body)
        assert_includes last_response.body, "<svg"
        assert_match(/aria-label="[^"]*distribution[^"]*"/i, last_response.body)
      end

      def test_engagement_high_struggle_score_gets_badge
        seed_high_struggle_session("e-hi")

        get "/analytics/engagement"

        assert_equal 200, last_response.status
        # The composite (41) crosses the 30 threshold → badge-warning on the
        # score cell. Bind the class to the score value so a threshold flip
        # (e.g. moving the warning cut-off above 41) fails the test.
        assert_match(/badge-warning[^>]*>\s*4\d\s*</, last_response.body)
      end

      def test_engagement_renders_replay_links
        seed_struggle_session("e-1", window_id: "w3")

        get "/analytics/engagement"

        assert_includes last_response.body, "/sessions/e-1/windows/w3?t=0"
        assert_includes last_response.body, "Open in player"
      end

      def test_engagement_labels_struggle_direction
        get "/analytics/engagement"

        assert_match(/higher\s*=\s*more\s*(struggle|friction)/i, last_response.body)
      end

      def test_engagement_sort_param_allowlist
        seed_struggle_session("e-1")

        get "/analytics/engagement?sort=duration"
        assert_equal 200, last_response.status

        get "/analytics/engagement?sort=bogus"
        assert_equal 200, last_response.status
        refute_includes last_response.body, "bogus"
      end

      def test_engagement_empty_state
        get "/analytics/engagement"

        assert_match(/no .*(session|data|engagement)/i, last_response.body)
      end

      def test_engagement_truncation_warning
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 1)
        seed_struggle_session("e-1")
        seed_struggle_session("e-2")

        get "/analytics/engagement"

        assert_equal 200, last_response.status
        assert_match(/truncat|capp|incomplete/i, last_response.body)
      end

      def test_engagement_renders_from_to_date_inputs
        get "/analytics/engagement"

        assert_includes last_response.body, 'name="since"'
        assert_includes last_response.body, 'name="until"'
      end

      def test_engagement_honors_date_range
        seed_struggle_session("e-1")
        yesterday = (Time.now.utc.to_date - 1).to_s
        today = Time.now.utc.to_date.to_s

        get "/analytics/engagement?until=#{yesterday}"
        refute_includes last_response.body, "shop.test/checkout"

        get "/analytics/engagement?since=#{today}&until=#{today}"
        assert_includes last_response.body, "shop.test/checkout"
      end

      def test_engagement_escapes_url_html
        seed_struggle_session("e-xss", url: "https://x.test/<script>alert(1)</script>")

        get "/analytics/engagement"

        refute_includes last_response.body, "<script>alert(1)</script>"
        assert_includes last_response.body, "&lt;script&gt;"
      end
    end
  end
end
