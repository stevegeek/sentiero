# frozen_string_literal: true

require "test_helper"
require "sentiero/web/analytics_app"
require "rack/test"

module Sentiero
  module Web
    # /analytics/page — the per-URL drill-down report (Plan 25, Task 3).
    class AnalyticsPagePageTest < Minitest::Test
      include Rack::Test::Methods

      URL = "https://example.com/signup"

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

      def meta(href, ts:, width: 1000, height: 800)
        {"type" => 4, "timestamp" => ts, "data" => {"href" => href, "width" => width, "height" => height}}
      end

      def click_event(x, y, ts:)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 2, "type" => 2, "x" => x, "y" => y}}
      end

      def click_tag(selector, ts:)
        {"type" => 5, "timestamp" => ts, "data" => {"tag" => "__click", "payload" => {"selector" => selector}}}
      end

      def input_event(id, ts:)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 5, "id" => id}}
      end

      def submit_event(ts:)
        {"type" => 5, "timestamp" => ts, "data" => {"tag" => "__form_submit", "payload" => {}}}
      end

      def perf_event(metric, value, rating, ts:)
        {"type" => 5, "timestamp" => ts, "data" => {"tag" => "__perf", "payload" => {"metric" => metric, "value" => value, "rating" => rating}}}
      end

      def error_event(message, ts:)
        {"type" => 5, "timestamp" => ts, "data" => {"tag" => "error", "payload" => {"message" => message}}}
      end

      def custom_event(tag, ts:)
        {"type" => 5, "timestamp" => ts, "data" => {"tag" => tag, "payload" => {}}}
      end

      def scroll_event(y, ts:)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 3, "x" => 0, "y" => y}}
      end

      # A rich single-session window that touches every sub-metric on URL.
      def seed_rich_session(id = "s-rich", window_id: "w1", url: URL)
        events = [meta(url, ts: now_ms)]
        # heatmap: two clicks, button.go selector tally
        events << click_event(10, 10, ts: now_ms + 1)
        events << click_tag("button.go", ts: now_ms + 1)
        events << click_event(11, 11, ts: now_ms + 2)
        events << click_tag("button.go", ts: now_ms + 2)
        # scroll
        events << scroll_event(1500, ts: now_ms + 3)
        # form: input + submit
        events << input_event(7, ts: now_ms + 4)
        events << submit_event(ts: now_ms + 5)
        # vitals
        events << perf_event("LCP", 4321.0, "poor", ts: now_ms + 100)
        # error
        events << error_event("Signup boom at line 42", ts: now_ms + 200)
        # custom event
        events << custom_event("promo_clicked", ts: now_ms + 300)
        # rage cluster on a broken button
        4.times do |i|
          events << click_event(50, 50, ts: now_ms + 400 + i * 50)
          events << click_tag("button.broken", ts: now_ms + 400 + i * 50)
        end
        # final timestamped event so the segment has a dwell sample
        events << scroll_event(1600, ts: now_ms + 5000)
        @store.save_events(Sentiero::WindowRef.new(id, window_id), events)
        @store.save_metadata(id, {"url" => url})
      end

      def get_page(url = URL, **params)
        qs = {"url" => url}.merge(params.transform_keys(&:to_s))
        get "/analytics/page?#{Rack::Utils.build_query(qs)}"
      end

      def test_page_report_returns_200_with_sections
        seed_rich_session

        get_page

        assert_equal 200, last_response.status
        body = last_response.body
        assert_includes body, "example.com/signup"
        # section headings
        assert_match(/Heatmap/i, body)
        assert_match(/Scroll/i, body)
        assert_match(/Forms/i, body)
        assert_match(/Web Vitals/i, body)
        assert_match(/Errors/i, body)
        assert_match(/Frustration/i, body)
        assert_match(/Custom Events/i, body)
        # a known seeded value: the rage selector + a form field label
        assert_includes body, "button.broken"
        assert_includes body, "promo_clicked"
        assert_includes body, "Signup boom"
      end

      def test_page_report_returns_403_when_auth_fails
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get_page

        assert_equal 403, last_response.status
      end

      def test_page_report_sets_security_headers_and_csrf_cookie
        get "/analytics/page"

        assert_equal "nosniff", last_response.headers["x-content-type-options"]
        assert_equal "DENY", last_response.headers["x-frame-options"]
        assert last_response.headers["content-security-policy"]
        assert_includes last_response.headers["set-cookie"], "sentiero_csrf="
        assert_includes last_response.headers["set-cookie"], "HttpOnly"
      end

      def test_page_report_picker_state_when_no_url
        seed_rich_session

        get "/analytics/page"

        assert_equal 200, last_response.status
        # The URL picker is present, but no report rendered (no analyze run).
        assert_includes last_response.body, 'name="url"'
        # The recorded page is offered in the picker.
        assert_includes last_response.body, "example.com/signup"
        # No per-section data without a selection.
        refute_includes last_response.body, "button.broken"
      end

      def test_page_report_empty_state_for_unknown_url
        seed_rich_session

        get_page("https://example.com/unknown")

        assert_equal 200, last_response.status
        assert_match(/No data recorded/i, last_response.body)
      end

      def test_page_report_renders_replay_links
        seed_rich_session

        get_page

        # An error occurrence / vitals worst link into the player carries ?t=.
        assert_match(%r{/sessions/s-rich/windows/w1\?t=\d+}, last_response.body)
      end

      def test_page_report_labels_raw_dead_clicks
        seed_rich_session

        get_page

        # The dead-click count must be labelled raw / pre-filter (B3 requirement).
        assert_match(/raw|pre-filter/i, last_response.body)
      end

      def test_page_report_renders_from_to_date_inputs
        get "/analytics/page"

        assert_includes last_response.body, 'name="since"'
        assert_includes last_response.body, 'name="until"'
      end

      def test_page_report_honors_date_range
        seed_rich_session
        yesterday = (Time.now.utc.to_date - 1).to_s
        today = Time.now.utc.to_date.to_s

        get_page(URL, until: yesterday)
        assert_match(/No data recorded/i, last_response.body)

        get_page(URL, since: today, until: today)
        assert_includes last_response.body, "button.broken"
      end

      def test_page_report_escapes_url
        evil = "https://x.test/<script>alert(1)</script>"
        @store.save_events(Sentiero::WindowRef.new("s-xss", "w1"),
          [meta(evil, ts: now_ms), scroll_event(10, ts: now_ms + 1)])
        @store.save_metadata("s-xss", {"url" => evil})

        get_page(evil)

        refute_includes last_response.body, "<script>alert(1)</script>"
        assert_includes last_response.body, "&lt;script&gt;"
      end
    end
  end
end
