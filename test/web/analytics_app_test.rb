# frozen_string_literal: true

require "test_helper"
require "sentiero/web/analytics_app"
require "rack/test"

module Sentiero
  module Web
    class AnalyticsAppTest < Minitest::Test
      include Rack::Test::Methods

      CHROME_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

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
        seed
      end

      def teardown
        Sentiero.reset_configuration!
      end

      def now_ms
        @now_ms ||= (Time.now.to_f * 1000).round
      end

      def seed
        @store.save_events(Sentiero::WindowRef.new("sess-1", "win-1"), [
          {"type" => 3, "timestamp" => now_ms},
          {"type" => 4, "timestamp" => now_ms + 1},
          {"type" => 5, "timestamp" => now_ms + 2, "data" => {"tag" => "click"}}
        ])
        @store.save_metadata("sess-1", {
          "userAgent" => CHROME_UA,
          "url" => "https://example.com/home",
          "entry_url" => "https://example.com/home",
          "entry_referrer" => "https://google.com/",
          "referrer" => "https://google.com/"
        })
      end

      def save_session_with_metadata(id, metadata)
        @store.save_events(Sentiero::WindowRef.new(id, "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata(id, metadata)
      end

      def test_overview_returns_200
        get "/analytics"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Analytics"
      end

      def test_overview_renders_metric_cards
        get "/analytics"

        assert_includes last_response.body, "Total Sessions"
        assert_includes last_response.body, "Total Events"
      end

      def test_analytics_pages_render_sub_navigation
        %w[/analytics /analytics/heatmap /analytics/scroll /analytics/forms
          /analytics/page /analytics/segments /analytics/vitals /analytics/frustration
          /analytics/funnel /analytics/engagement /analytics/conversions
          /analytics/export].each do |path|
          get path
          assert_equal 200, last_response.status, "expected 200 for #{path}"
          assert_includes last_response.body, "/analytics/vitals", "nav missing on #{path}"
          assert_includes last_response.body, "/analytics/frustration", "nav missing on #{path}"
          assert_includes last_response.body, "/analytics/funnel", "nav missing on #{path}"
          assert_includes last_response.body, "/analytics/engagement", "nav missing on #{path}"
          assert_includes last_response.body, "/analytics/page", "Pages nav tab missing on #{path}"
        end
      end

      def test_analytics_sub_navigation_carries_active_range
        get "/analytics?since=2026-06-01&until=2026-06-10"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "/analytics/vitals?since=2026-06-01&amp;until=2026-06-10"
      end

      def test_analytics_overview_links_to_client_errors_page
        get "/analytics"

        assert_includes last_response.body, "/issues?source=client"
        assert_includes last_response.body, "View all JS errors"
      end

      def test_overview_renders_distributions
        get "/analytics"

        assert_includes last_response.body, "Chrome"
        assert_includes last_response.body, "Desktop"
        assert_includes last_response.body, "example.com/home"
        assert_includes last_response.body, "google.com"
        assert_includes last_response.body, "click"
      end

      def test_overview_shows_countries_card_when_geo_data_present
        save_session_with_metadata("s-geo", {"geo_country" => "DE", "geo_city" => "Berlin"})

        get "/analytics"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Countries"
        assert_includes last_response.body, "DE"
        assert_includes last_response.body, "Berlin"
      end

      def test_overview_hides_countries_card_without_geo_data
        save_session_with_metadata("s-plain", {"plan" => "pro"})

        get "/analytics"

        assert_equal 200, last_response.status
        refute_includes last_response.body, ">Countries<"
      end

      def test_overview_renders_error_stat_cards_with_links
        @store.save_occurrence({
          "fingerprint" => "fp-overview-1",
          "project" => "app",
          "exception_class" => "RuntimeError",
          "message" => "boom",
          "timestamp" => Time.now.to_f
        })
        @store.save_events(Sentiero::WindowRef.new("sess-err", "win-1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("sess-err", {"has_errors" => true})

        get "/analytics"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Open Problems"
        assert_includes last_response.body, "Sessions with Errors"
        assert_includes last_response.body, "/issues"
        assert_includes last_response.body, "has_errors=true"
      end

      # ── B3: top-problems card + "new" badge ──

      def test_overview_renders_top_problems_card_with_new_badge
        @store.save_occurrence({"fingerprint" => "fp-top-1", "project" => "app",
          "exception_class" => "RuntimeError", "message" => "top boom",
          "timestamp" => Time.now.to_f})

        get "/analytics"

        body = last_response.body
        assert_includes body, "Top Problems"
        assert_includes body, "/issues/fp-top-1"
        assert_includes body, "top boom"
        assert_includes body, ">new</span>"
      end

      def test_overview_top_problems_old_problem_has_no_new_badge
        @store.save_occurrence({"fingerprint" => "fp-old-1", "project" => "app",
          "exception_class" => "RuntimeError", "message" => "ancient boom",
          "timestamp" => Time.now.to_f - 60 * 86_400})

        get "/analytics"

        body = last_response.body
        assert_includes body, "/issues/fp-old-1"
        refute_includes body, ">new</span>"
      end

      def test_overview_omits_top_problems_card_without_problems
        get "/analytics"

        refute_includes last_response.body, "Top Problems"
      end

      # ── B5: error-free-rate card ──

      def test_overview_renders_error_free_rate_card
        # Seeded sess-1 has no errors; add one errored session → 50% error-free.
        @store.save_events(Sentiero::WindowRef.new("sess-err", "win-1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("sess-err", {"has_errors" => true})

        get "/analytics"

        body = last_response.body
        assert_includes body, "Error-Free Sessions"
        assert_includes body, "50.0%"
        assert_includes body, "has_errors=true"
      end

      def test_overview_error_free_rate_guards_zero_sessions
        a_year_ago = (Time.now.utc.to_date - 365).to_s

        get "/analytics?since=#{a_year_ago}&until=#{a_year_ago}"

        body = last_response.body
        assert_includes body, "Error-Free Sessions"
        assert_includes body, "N/A"
      end

      def test_overview_shows_per_day_error_count
        # Seed a session with a browser JS error (type==5, data.tag=="error") today
        @store.save_events(Sentiero::WindowRef.new("sess-err-day", "win-1"), [
          {"type" => 3, "timestamp" => now_ms},
          {"type" => 5, "timestamp" => now_ms + 100,
           "data" => {"tag" => "error", "payload" => {"message" => "Uncaught TypeError"}}}
        ])

        get "/analytics"

        assert_equal 200, last_response.status
        # The chart renders a per-day error badge with data-error-count attribute
        assert_includes last_response.body, "data-error-count=\"1\""
      end

      # ── C6: visible session series + server-exception overlay ──

      def test_overview_chart_renders_visible_session_series
        get "/analytics"

        # Seeded sess-1 is today's only session: a visible (non-tooltip)
        # element carries the per-day session count.
        assert_includes last_response.body, 'data-session-count="1"'
      end

      def test_overview_chart_renders_server_exception_day_count
        @store.save_occurrence({"fingerprint" => "fp-chart-1", "project" => "app",
          "exception_class" => "RuntimeError", "message" => "boom",
          "timestamp" => Time.now.to_f})

        get "/analytics"

        assert_equal 200, last_response.status
        assert_includes last_response.body, 'data-server-error-count="1"'
      end

      def test_overview_chart_omits_server_overlay_without_occurrences
        get "/analytics"

        refute_includes last_response.body, "data-server-error-count"
      end

      def test_overview_chart_server_overlay_distinct_from_js_errors
        @store.save_events(Sentiero::WindowRef.new("sess-js-err", "w1"), [
          {"type" => 3, "timestamp" => now_ms},
          {"type" => 5, "timestamp" => now_ms + 1,
           "data" => {"tag" => "error", "payload" => {"message" => "Uncaught"}}}
        ])
        @store.save_occurrence({"fingerprint" => "fp-chart-2", "project" => "app",
          "exception_class" => "RuntimeError", "message" => "boom",
          "timestamp" => Time.now.to_f})

        get "/analytics"

        body = last_response.body
        # Both annotations render, each with its own marker (client amber,
        # server red).
        assert_includes body, 'data-error-count="1"'
        assert_includes body, 'data-server-error-count="1"'
        assert_match(/JS error/i, body)
        assert_match(/server exception/i, body)
      end

      def test_overview_chart_notes_truncated_server_overlay
        Sentiero::Analytics::StatsAggregator::MAX_OCCURRENCES_PER_PROBLEM.times do |i|
          @store.save_occurrence({"fingerprint" => "fp-flood", "project" => "app",
            "exception_class" => "RuntimeError", "message" => "flood",
            "timestamp" => Time.now.to_f - i})
        end

        get "/analytics"

        assert_equal 200, last_response.status
        assert_match(/overlay truncated|lower bound/i, last_response.body)
      end

      # ── B8 + B9: navigation + metadata panels ──

      def test_overview_renders_navigation_panel
        @store.save_events(Sentiero::WindowRef.new("sess-nav", "w1"), [
          {"type" => 5, "timestamp" => now_ms, "data" => {"tag" => "navigation",
                                                          "payload" => {"url" => "https://example.com/pricing", "text" => "Pricing"}}},
          {"type" => 5, "timestamp" => now_ms + 1, "data" => {"tag" => "navigation",
                                                              "payload" => {"url" => "https://partner.test/", "text" => "Partner", "external" => true}}}
        ])

        get "/analytics"

        body = last_response.body
        assert_includes body, "Navigation Clicks"
        assert_includes body, "https://example.com/pricing"
        assert_includes body, "https://partner.test/"
        assert_match(/internal destinations/i, body)
        assert_match(/external destinations/i, body)
        assert_includes body, "Pricing"
      end

      def test_overview_navigation_panel_empty_state
        get "/analytics"

        assert_match(/No navigation clicks/i, last_response.body)
      end

      def test_overview_renders_metadata_panel_with_segment_links
        @store.save_events(Sentiero::WindowRef.new("sess-meta", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("sess-meta", {"plan" => "pro"})

        get "/analytics"

        body = last_response.body
        assert_includes body, "Session Metadata"
        assert_includes body, "plan"
        assert_includes body, "/analytics/segments?metadata_key=plan&amp;metadata_value=pro"
      end

      def test_overview_metadata_panel_empty_state_hides_internal_keys
        # Seeded sess-1 carries only recorder-internal metadata (userAgent,
        # url, referrer) which must not surface as custom keys.
        get "/analytics"

        assert_match(/No custom metadata/i, last_response.body)
      end

      def test_overview_metadata_panel_escapes_values
        @store.save_events(Sentiero::WindowRef.new("sess-meta-xss", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("sess-meta-xss", {"note" => "<script>alert(1)</script>"})

        get "/analytics"

        refute_includes last_response.body, "<script>alert(1)</script>"
      end

      # ── B6: entry-page error-rate column ──

      def test_overview_entry_pages_show_err_pct_and_segment_links
        # Seeded sess-1 entered /home without errors; add an errored entry on
        # the same page → 50% entry-page error correlation.
        @store.save_events(Sentiero::WindowRef.new("sess-eperr", "win-1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("sess-eperr", {"entry_url" => "https://example.com/home", "has_errors" => true})

        get "/analytics"

        body = last_response.body
        assert_includes body, 'data-entry-err-pct="50"'
        # Row links to a prefilled errored-sessions segment for the page.
        assert_includes body,
          "/analytics/segments?url_pattern=https%3A%2F%2Fexample.com%2Fhome&amp;has_errors=true"
        # Honest labeling: correlation with the entry page, not the error page.
        assert_match(/entry-page correlation/i, body)
      end

      def test_overview_entry_pages_err_pct_zero_without_errors
        get "/analytics"

        assert_includes last_response.body, 'data-entry-err-pct="0"'
      end

      def test_overview_entry_pages_panel_states_method
        # C2 (P2.2): honest labeling — one-line note on how "entry" is derived.
        get "/analytics"

        assert_match(/entry = first page seen in the recording/i, last_response.body)
      end

      def test_overview_returns_403_when_auth_fails
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/analytics"

        assert_equal 403, last_response.status
      end

      def test_overview_returns_security_headers
        get "/analytics"

        assert_equal "nosniff", last_response.headers["x-content-type-options"]
        assert_equal "DENY", last_response.headers["x-frame-options"]
        assert last_response.headers["content-security-policy"]
      end

      def test_overview_sets_csrf_cookie
        get "/analytics"

        cookie = last_response.headers["set-cookie"]
        assert cookie
        assert_includes cookie, "sentiero_csrf="
        assert_includes cookie, "HttpOnly"
      end

      def test_range_param_controls_window
        get "/analytics?range=14"

        assert_equal 200, last_response.status
        # the range selector reflects the active choice and offers all ranges
        assert_match(/value="14"\s+selected/, last_response.body)
        assert_includes last_response.body, "Last 90 days"
      end

      def test_invalid_range_falls_back_to_default
        get "/analytics?range=evil"

        assert_equal 200, last_response.status
      end

      def test_negative_range_falls_back_to_default
        get "/analytics?range=-1"

        assert_equal 200, last_response.status
      end

      # ── custom from/to range ──

      def test_overview_renders_from_to_date_inputs
        get "/analytics"

        assert_equal 200, last_response.status
        assert_includes last_response.body, 'name="since"'
        assert_includes last_response.body, 'name="until"'
        assert_includes last_response.body, 'type="date"'
      end

      def test_overview_custom_range_excludes_out_of_range_data
        a_week_ago = (Time.now.utc.to_date - 7).to_s

        get "/analytics?since=#{a_week_ago}&until=#{a_week_ago}"

        assert_equal 200, last_response.status
        # Seeded data is from today, outside the selected window.
        assert_includes last_response.body, "No events in this range."
      end

      def test_overview_custom_until_today_is_inclusive
        today = Time.now.utc.to_date.to_s

        get "/analytics?since=#{today}&until=#{today}"

        assert_equal 200, last_response.status
        # Regression: a date-only `until` used to cut the window at 00:00,
        # silently dropping the selected To-day (today's seeded events).
        refute_includes last_response.body, "No events in this range."
      end

      def test_overview_form_reflects_custom_range
        get "/analytics?since=2026-06-01&until=2026-06-10"

        assert_equal 200, last_response.status
        assert_includes last_response.body, 'value="2026-06-01"'
        assert_includes last_response.body, 'value="2026-06-10"'
      end

      def test_overview_cross_links_carry_custom_range
        get "/analytics?since=2026-06-01&until=2026-06-10"

        # Range-scoped cross-links (errored-sessions card, JS-errors button)
        # carry the active window to their target pages.
        assert_includes last_response.body, "has_errors=true&amp;since=2026-06-01&amp;until=2026-06-10"
        assert_includes last_response.body, "/issues?source=client&amp;since=2026-06-01&amp;until=2026-06-10"
      end

      # ── C4: period-over-period deltas on overview cards ──

      # Sessions stamp updated_at with the wall clock, so prior-window data is
      # seeded under a stubbed Time.now one day in the past.
      def seed_yesterday_session(id, has_errors: false)
        yesterday = Time.now - 86_400
        Time.stub(:now, yesterday) do
          ts = (yesterday.to_f * 1000).round
          @store.save_events(Sentiero::WindowRef.new(id, "w1"), [{"type" => 3, "timestamp" => ts}])
          @store.save_metadata(id, {"has_errors" => true}) if has_errors
        end
      end

      def test_overview_renders_period_over_period_deltas
        today = Time.now.utc.to_date.to_s
        # Today: seeded sess-1 (3 events) + one more session = 2 sessions / 4 events.
        @store.save_events(Sentiero::WindowRef.new("sess-today-2", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        # Prior window (yesterday): 1 session / 1 event.
        seed_yesterday_session("sess-yesterday")

        get "/analytics?since=#{today}&until=#{today}"

        body = last_response.body
        assert_includes body, 'data-delta-sessions="100.0"' # 2 vs 1
        assert_includes body, 'data-delta-events="300.0"'   # 4 vs 1
        assert_includes body, "&#9650;"
      end

      def test_overview_deltas_show_negative_direction
        today = Time.now.utc.to_date.to_s
        # Today: only the seeded sess-1. Yesterday: two sessions → -50%.
        seed_yesterday_session("y1")
        seed_yesterday_session("y2")

        get "/analytics?since=#{today}&until=#{today}"

        assert_includes last_response.body, 'data-delta-sessions="-50.0"'
        assert_includes last_response.body, "&#9660;"
      end

      def test_overview_error_free_rate_delta_in_percentage_points
        today = Time.now.utc.to_date.to_s
        # Yesterday: 2 sessions, 1 errored (50% error-free). Today: sess-1
        # only, no errors (100%) → +50.0pp.
        seed_yesterday_session("y-ok")
        seed_yesterday_session("y-err", has_errors: true)

        get "/analytics?since=#{today}&until=#{today}"

        assert_includes last_response.body, 'data-delta-error-free="50.0"'
      end

      def test_overview_deltas_omitted_when_prior_window_empty
        today = Time.now.utc.to_date.to_s

        get "/analytics?since=#{today}&until=#{today}"

        assert_equal 200, last_response.status
        # Zero-denominator guard: no prior sessions/events → no deltas.
        refute_includes last_response.body, "data-delta-sessions"
        refute_includes last_response.body, "data-delta-events"
        refute_includes last_response.body, "data-delta-error-free"
      end

      def test_overview_delta_comparison_skipped_when_scan_truncated
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 1)
        seed_yesterday_session("sess-yesterday")
        today = Time.now.utc.to_date.to_s

        get "/analytics?since=#{today}&until=#{today}"

        # The primary scan hit the cap: don't double a maxed-out scan with a
        # comparison pass (and the numbers would be truncated anyway).
        assert_equal 200, last_response.status
        refute_includes last_response.body, "data-delta-sessions"
      end

      # Counts store scans so we can prove the overview computes deltas from a
      # single widened pass, not two.
      class CountingMemory < Stores::Memory
        attr_reader :scan_count

        def initialize(*)
          super
          @scan_count = 0
        end

        def each_session_events(**kwargs, &block)
          @scan_count += 1 if block
          super
        end
      end

      def test_overview_computes_deltas_in_a_single_scan
        @store = CountingMemory.new
        Sentiero.configuration.store = @store
        today = Time.now.utc.to_date.to_s
        @store.save_events(Sentiero::WindowRef.new("today-1", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        seed_yesterday_session("yesterday-1")

        get "/analytics?since=#{today}&until=#{today}"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "data-delta-sessions"
        assert_equal 1, @store.scan_count, "overview should scan the store exactly once when computing deltas"
      end

      def test_html_injection_in_metadata_is_escaped
        @store.save_events(Sentiero::WindowRef.new("sess-xss", "win-1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("sess-xss", {"entry_url" => "https://x.com/<script>alert(1)</script>"})

        get "/analytics"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "<script>alert(1)</script>"
        assert_includes last_response.body, "&lt;script&gt;"
      end

      # ── segments ──

      SAFARI_IPHONE_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

      def seed_segment_sessions
        @store.save_events(Sentiero::WindowRef.new("seg-chrome", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("seg-chrome", {"userAgent" => CHROME_UA, "url" => "https://shop.test/cart", "plan" => "pro"})

        @store.save_events(Sentiero::WindowRef.new("seg-mobile", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("seg-mobile", {"userAgent" => SAFARI_IPHONE_UA, "url" => "https://shop.test/home", "has_errors" => true})
      end

      def test_segments_returns_200_with_filter_form
        get "/analytics/segments"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Segments"
        assert_includes last_response.body, 'name="browser"'
        assert_includes last_response.body, 'name="device"'
        assert_includes last_response.body, 'name="url_pattern"'
        assert_includes last_response.body, 'name="metadata_key"'
        assert_includes last_response.body, 'name="has_errors"'
      end

      def test_segments_returns_403_when_auth_fails
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/analytics/segments"

        assert_equal 403, last_response.status
      end

      def test_segments_sets_security_headers_and_csrf_cookie
        get "/analytics/segments"

        assert_equal "nosniff", last_response.headers["x-content-type-options"]
        assert_includes last_response.headers["set-cookie"], "sentiero_csrf="
      end

      def test_segments_filters_by_browser
        seed_segment_sessions

        get "/analytics/segments?browser=Chrome"

        assert_includes last_response.body, "seg-chro"
        refute_includes last_response.body, "seg-mobi"
      end

      def test_segments_filters_by_device
        seed_segment_sessions

        get "/analytics/segments?device=Mobile"

        assert_includes last_response.body, "seg-mobi"
        refute_includes last_response.body, "seg-chro"
      end

      def test_segments_filters_by_url_pattern
        seed_segment_sessions

        get "/analytics/segments?url_pattern=cart"

        assert_includes last_response.body, "seg-chro"
        refute_includes last_response.body, "seg-mobi"
      end

      def test_segments_filters_by_metadata_key_value
        seed_segment_sessions

        get "/analytics/segments?metadata_key=plan&metadata_value=pro"

        assert_includes last_response.body, "seg-chro"
        refute_includes last_response.body, "seg-mobi"
      end

      def test_segments_filters_by_has_errors
        seed_segment_sessions

        get "/analytics/segments?has_errors=true"

        assert_includes last_response.body, "seg-mobi"
        refute_includes last_response.body, "seg-chro"
      end

      def test_segments_combines_filters_with_and_logic
        seed_segment_sessions

        get "/analytics/segments?device=Mobile&url_pattern=cart"

        # The only mobile session is on /home, so nothing matches both predicates.
        refute_includes last_response.body, "seg-chro"
        refute_includes last_response.body, "seg-mobi"
        assert_match(/No sessions matched/i, last_response.body)
      end

      def test_segments_escapes_filter_values
        get "/analytics/segments?url_pattern=%3Cscript%3Ealert(1)%3C%2Fscript%3E"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "<script>alert(1)</script>"
        assert_includes last_response.body, "&lt;script&gt;"
      end

      def test_segments_escapes_metadata_in_session_rows
        @store.save_events(Sentiero::WindowRef.new("seg-xss", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("seg-xss", {"url" => "https://x.test/<script>alert(1)</script>"})

        get "/analytics/segments"

        refute_includes last_response.body, "<script>alert(1)</script>"
      end

      def test_segments_pagination_clamps_per_page
        get "/analytics/segments?per_page=99999&page=0"

        assert_equal 200, last_response.status
      end

      def test_segments_truncation_warning_shown_when_capped
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 1)
        seed_segment_sessions

        get "/analytics/segments"

        assert_equal 200, last_response.status
        assert_match(/truncat|capp|incomplete/i, last_response.body)
      end

      def test_segments_form_renders_from_to_date_inputs
        get "/analytics/segments"

        assert_equal 200, last_response.status
        assert_includes last_response.body, 'name="since"'
        assert_includes last_response.body, 'name="until"'
      end

      def test_segments_date_range_excludes_out_of_range_sessions
        seed_segment_sessions
        yesterday = (Time.now.utc.to_date - 1).to_s

        get "/analytics/segments?until=#{yesterday}"

        refute_includes last_response.body, "seg-chro"
        refute_includes last_response.body, "seg-mobi"
        assert_match(/No sessions matched/i, last_response.body)
      end

      def test_segments_until_today_is_inclusive
        # Regression: the To-day must include sessions updated later that day.
        seed_segment_sessions
        today = Time.now.utc.to_date.to_s

        get "/analytics/segments?since=#{today}&until=#{today}"

        assert_includes last_response.body, "seg-chro"
        assert_includes last_response.body, "seg-mobi"
      end

      def test_segments_pagination_preserves_date_range
        seed_segment_sessions
        today = Time.now.utc.to_date.to_s

        get "/analytics/segments?since=#{today}&until=#{today}&per_page=1"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "since=#{today}"
        assert_includes last_response.body, "until=#{today}"
      end

      def test_segments_filters_by_country
        save_session_with_metadata("s-de", {"geo_country" => "DE"})
        save_session_with_metadata("s-pt", {"geo_country" => "PT"})

        get "/analytics/segments", {"country" => "DE"}

        assert_equal 200, last_response.status
        assert_includes last_response.body, "s-de"
        refute_includes last_response.body, "s-pt"
      end

      def test_segments_country_param_rejects_non_iso_codes
        save_session_with_metadata("s-de", {"geo_country" => "DE"})

        get "/analytics/segments", {"country" => "<script>"}

        assert_equal 200, last_response.status
        assert_includes last_response.body, "s-de"
      end

      # ── errors ──

      def seed_error_session(id, window_id, payload, at: now_ms)
        @store.save_events(Sentiero::WindowRef.new(id, window_id), [
          {"type" => 3, "timestamp" => at},
          {"type" => 5, "timestamp" => at + 500, "data" => {"tag" => "error", "payload" => payload}}
        ])
      end

      def test_overview_clickable_event_tags_link_to_custom_events
        # Seed an "error"-tagged custom event: it has its own surface and is
        # excluded from the tags panel (see the exclusion tests below).
        @store.save_events(Sentiero::WindowRef.new("sess-tag-err", "win-1"), [
          {"type" => 5, "timestamp" => now_ms, "data" => {"tag" => "error", "payload" => {"message" => "boom"}}}
        ])

        get "/analytics"
        assert_equal 200, last_response.status

        # The seed has a "click" browser custom event (type-5, non-error tag); it
        # links into the browser-events tab via source=browser.
        assert_includes last_response.body, "/custom-events?source=browser&amp;search=click"
      end

      # ── C5(a): internal tags excluded from the Custom Event Tags panel ──

      def test_overview_event_tags_panel_excludes_error_tag
        @store.save_events(Sentiero::WindowRef.new("sess-tag-err", "win-1"), [
          {"type" => 5, "timestamp" => now_ms, "data" => {"tag" => "error", "payload" => {"message" => "boom"}}}
        ])

        get "/analytics"
        assert_equal 200, last_response.status

        # JS errors have their own surface (/issues?source=client, linked from
        # the chart card); the tags panel never lists or links the error tag.
        refute_includes last_response.body, "/custom-events?search=error"
        refute_includes last_response.body, "/custom-events?source=browser&amp;search=error"
      end

      def test_overview_event_tags_panel_excludes_internal_recorder_tags
        @store.save_events(Sentiero::WindowRef.new("sess-internal", "win-1"), [
          {"type" => 5, "timestamp" => now_ms,
           "data" => {"tag" => "__perf", "payload" => {"metric" => "LCP", "value" => 1200, "rating" => "good"}}},
          {"type" => 5, "timestamp" => now_ms + 1,
           "data" => {"tag" => "__click", "payload" => {"selector" => "button.add"}}}
        ])

        get "/analytics"
        assert_equal 200, last_response.status

        # Recorder-internal annotations never surface as custom event tags.
        refute_includes last_response.body, "search=__perf"
        refute_includes last_response.body, "search=__click"
        refute_includes last_response.body, ">__perf</a>"
        refute_includes last_response.body, ">__click</a>"
      end

      def test_overview_event_tags_render_inline_day_series
        @store.save_events(Sentiero::WindowRef.new("sess-series", "win-1"), [
          {"type" => 5, "timestamp" => now_ms, "data" => {"tag" => "checkout"}},
          {"type" => 5, "timestamp" => now_ms + 1, "data" => {"tag" => "checkout"}}
        ])

        get "/analytics"
        assert_equal 200, last_response.status

        body = last_response.body
        assert_includes body, 'data-tag-series="checkout"'
        # today's bucket tooltip carries the count
        assert_includes body, "#{Time.now.utc.to_date}: 2"
      end

      # ── heatmap ──

      def seed_heatmap_session(id, url:, width: 1000, height: 1000, clicks: [[100, 100]])
        events = [{"type" => 4, "timestamp" => now_ms, "data" => {"href" => url, "width" => width, "height" => height}}]
        clicks.each_with_index do |(x, y), i|
          ts = now_ms + i + 1
          events << {"type" => 3, "timestamp" => ts, "data" => {"source" => 2, "type" => 2, "x" => x, "y" => y}}
          events << {"type" => 5, "timestamp" => ts, "data" => {"tag" => "__click", "payload" => {"selector" => "button.add"}}}
        end
        @store.save_events(Sentiero::WindowRef.new(id, "w1"), events)
        @store.save_metadata(id, {"url" => url})
      end

      def test_heatmap_returns_200_with_heading_and_url_picker
        seed_heatmap_session("hm-1", url: "https://shop.test/cart")

        get "/analytics/heatmap"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Click Heatmaps"
        assert_includes last_response.body, 'name="url"'
        assert_includes last_response.body, "shop.test/cart"
      end

      def test_heatmap_links_to_page_report
        seed_heatmap_session("hm-1", url: "https://shop.test/cart")

        get "/analytics/heatmap?url=https%3A%2F%2Fshop.test%2Fcart"

        assert_includes last_response.body, "/analytics/page?url="
        assert_match(/Page report/i, last_response.body)
      end

      def test_heatmap_truncation_warning_shown_when_capped
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 1)
        seed_heatmap_session("hm-1", url: "https://shop.test/cart")
        seed_heatmap_session("hm-2", url: "https://shop.test/cart")

        get "/analytics/heatmap"

        assert_equal 200, last_response.status
        assert_match(/truncat|capp|incomplete/i, last_response.body)
      end

      def test_heatmap_returns_403_when_auth_fails
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/analytics/heatmap"

        assert_equal 403, last_response.status
      end

      def test_heatmap_sets_security_headers_and_csrf_cookie
        get "/analytics/heatmap"

        assert_equal "nosniff", last_response.headers["x-content-type-options"]
        assert_includes last_response.headers["set-cookie"], "sentiero_csrf="
      end

      def test_heatmap_json_returns_aggregated_data
        seed_heatmap_session("hm-1", url: "https://shop.test/cart", clicks: [[100, 100], [110, 110]])

        get "/analytics/heatmap.json?url=https%3A%2F%2Fshop.test%2Fcart"

        assert_equal 200, last_response.status
        assert_equal "application/json", last_response.headers["content-type"]
        assert_equal "nosniff", last_response.headers["x-content-type-options"]
        data = JSON.parse(last_response.body)
        assert_equal 2, data["total_clicks"]
        assert_equal "button.add", data["top_elements"].first["selector"]
        assert_equal({"session_id" => "hm-1", "window_id" => "w1"}, data["representative_window"])
      end

      def test_heatmap_json_returns_403_when_auth_fails
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/analytics/heatmap.json?url=https%3A%2F%2Fshop.test%2Fcart"

        assert_equal 403, last_response.status
      end

      def test_heatmap_json_empty_for_unknown_url
        get "/analytics/heatmap.json?url=https%3A%2F%2Funknown.test%2F"

        assert_equal 200, last_response.status
        data = JSON.parse(last_response.body)
        assert_equal 0, data["total_clicks"]
        assert_empty data["clicks_by_bucket"]
      end

      def test_heatmap_json_without_url_returns_empty
        get "/analytics/heatmap.json"

        assert_equal 200, last_response.status
        data = JSON.parse(last_response.body)
        assert_equal 0, data["total_clicks"]
      end

      def test_heatmap_escapes_url_in_picker
        seed_heatmap_session("hm-xss", url: "https://x.test/<script>alert(1)</script>")

        get "/analytics/heatmap"

        refute_includes last_response.body, "<script>alert(1)</script>"
        assert_includes last_response.body, "&lt;script&gt;"
      end

      def test_heatmap_form_renders_from_to_date_inputs
        get "/analytics/heatmap"

        assert_includes last_response.body, 'name="since"'
        assert_includes last_response.body, 'name="until"'
      end

      def test_heatmap_caption_carries_estimation_caveat
        # C2 (P2.2): the page-coordinate caption (A2) gains an explicit
        # estimation caveat for pages that were never scrolled.
        seed_heatmap_session("hm-1", url: "https://shop.test/cart")

        get "/analytics/heatmap"

        body = last_response.body
        assert_match(/estimated page height/i, body)
        assert_match(/never scrolled/i, body)
      end

      def test_heatmap_page_carries_range_into_json_url
        seed_heatmap_session("hm-1", url: "https://shop.test/cart")

        get "/analytics/heatmap?since=2026-06-01&until=2026-06-10"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "heatmap.json"
        # The canvas fetch must carry the active range (config JSON island).
        assert_includes last_response.body, "since=2026-06-01"
        assert_includes last_response.body, "until=2026-06-10"
      end

      def test_heatmap_json_honors_date_range
        seed_heatmap_session("hm-1", url: "https://shop.test/cart", clicks: [[100, 100]])
        yesterday = (Time.now.utc.to_date - 1).to_s
        today = Time.now.utc.to_date.to_s

        get "/analytics/heatmap.json?url=https%3A%2F%2Fshop.test%2Fcart&until=#{yesterday}"
        assert_equal 0, JSON.parse(last_response.body)["total_clicks"]

        # The To-day is inclusive (regression: until=<today> used to cut at 00:00).
        get "/analytics/heatmap.json?url=https%3A%2F%2Fshop.test%2Fcart&since=#{today}&until=#{today}"
        assert_equal 1, JSON.parse(last_response.body)["total_clicks"]
      end

      # ── scroll depth ──

      def seed_scroll_session(id, url:, height: 800, scrolls: [1500], window_id: "w1")
        events = [{"type" => 4, "timestamp" => now_ms, "data" => {"href" => url, "width" => 1000, "height" => height}}]
        scrolls.each_with_index do |y, i|
          events << {"type" => 3, "timestamp" => now_ms + i + 1, "data" => {"source" => 3, "x" => 0, "y" => y}}
        end
        @store.save_events(Sentiero::WindowRef.new(id, window_id), events)
        @store.save_metadata(id, {"url" => url})
      end

      def test_scroll_returns_200_with_heading
        seed_scroll_session("sc-1", url: "https://shop.test/article")

        get "/analytics/scroll"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Scroll Depth"
        assert_includes last_response.body, "shop.test/article"
      end

      def test_scroll_links_to_page_report
        seed_scroll_session("sc-1", url: "https://shop.test/article")

        get "/analytics/scroll"

        assert_includes last_response.body, "/analytics/page?url="
        assert_match(/Page report/i, last_response.body)
      end

      def test_scroll_returns_403_when_auth_fails
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/analytics/scroll"

        assert_equal 403, last_response.status
      end

      def test_scroll_sets_security_headers_and_csrf_cookie
        get "/analytics/scroll"

        assert_equal "nosniff", last_response.headers["x-content-type-options"]
        assert_includes last_response.headers["set-cookie"], "sentiero_csrf="
        assert_includes last_response.headers["set-cookie"], "HttpOnly"
      end

      def test_scroll_renders_histogram_and_fold_markers
        seed_scroll_session("sc-1", url: "https://shop.test/article", scrolls: [1500])

        get "/analytics/scroll"

        # Hand-rolled SVG histogram with the four distribution bins.
        assert_includes last_response.body, "<svg"
        assert_includes last_response.body, "<rect"
        assert_includes last_response.body, "75-100"
        # Fold-line percentiles.
        assert_match(/50th|p50|50%/i, last_response.body)
      end

      def test_scroll_shows_empty_state_with_no_scroll_data
        get "/analytics/scroll"

        assert_match(/No scroll/i, last_response.body)
      end

      def test_scroll_escapes_url_html
        seed_scroll_session("sc-xss", url: "https://x.test/<script>alert(1)</script>")

        get "/analytics/scroll"

        refute_includes last_response.body, "<script>alert(1)</script>"
        assert_includes last_response.body, "&lt;script&gt;"
      end

      def test_scroll_truncation_warning_shown_when_capped
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 1)
        seed_scroll_session("sc-1", url: "https://shop.test/a")
        seed_scroll_session("sc-2", url: "https://shop.test/b")

        get "/analytics/scroll"

        assert_equal 200, last_response.status
        assert_match(/truncat|capp|incomplete/i, last_response.body)
      end

      def test_scroll_renders_from_to_date_inputs
        get "/analytics/scroll"

        assert_includes last_response.body, 'name="since"'
        assert_includes last_response.body, 'name="until"'
      end

      def test_scroll_honors_date_range
        seed_scroll_session("sc-1", url: "https://shop.test/article")
        yesterday = (Time.now.utc.to_date - 1).to_s
        today = Time.now.utc.to_date.to_s

        get "/analytics/scroll?until=#{yesterday}"
        assert_match(/No scroll/i, last_response.body)

        get "/analytics/scroll?since=#{today}&until=#{today}"
        assert_includes last_response.body, "shop.test/article"
      end

      # ── forms ──

      def seed_form_session(id, field_ids:, submitted: true, window_id: "w1")
        events = field_ids.each_with_index.map do |field_id, i|
          {"type" => 3, "timestamp" => now_ms + i, "data" => {"source" => 5, "id" => field_id, "text" => "*"}}
        end
        # A REAL submit: the recorder's __form_submit custom event (bare
        # navigations no longer count as submits).
        events << {"type" => 5, "timestamp" => now_ms + 100, "data" => {"tag" => "__form_submit", "payload" => {"url" => "https://x.test/"}}} if submitted
        @store.save_events(Sentiero::WindowRef.new(id, window_id), events)
      end

      def test_forms_returns_200_with_heading
        seed_form_session("fm-1", field_ids: [10, 11])

        get "/analytics/forms"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Form Analytics"
      end

      def test_forms_returns_403_when_auth_fails
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/analytics/forms"

        assert_equal 403, last_response.status
      end

      def test_forms_sets_security_headers_and_csrf_cookie
        get "/analytics/forms"

        assert_equal "nosniff", last_response.headers["x-content-type-options"]
        assert_includes last_response.headers["set-cookie"], "sentiero_csrf="
        assert_includes last_response.headers["set-cookie"], "HttpOnly"
      end

      def test_forms_renders_per_field_and_drop_off_tables
        seed_form_session("done", field_ids: [10, 11])
        seed_form_session("left", field_ids: [10, 11], submitted: false)

        get "/analytics/forms"

        assert_includes last_response.body, "Per-Field Metrics"
        assert_includes last_response.body, "Top Drop-off Fields"
        assert_includes last_response.body, "Completion Rate"
        assert_includes last_response.body, "Form Submits"
        # Field 11 is the last touched in the abandoned session.
        assert_includes last_response.body, "Field #11"
      end

      def test_forms_shows_empty_state_with_no_form_data
        get "/analytics/forms"

        assert_match(/No form interactions/i, last_response.body)
      end

      def test_forms_truncation_warning_shown_when_capped
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 1)
        seed_form_session("fm-1", field_ids: [10])
        seed_form_session("fm-2", field_ids: [11])

        get "/analytics/forms"

        assert_equal 200, last_response.status
        assert_match(/truncat|capp|incomplete/i, last_response.body)
      end

      def test_forms_renders_from_to_date_inputs
        get "/analytics/forms"

        assert_includes last_response.body, 'name="since"'
        assert_includes last_response.body, 'name="until"'
      end

      def test_forms_honors_date_range
        seed_form_session("fm-1", field_ids: [10, 11])
        yesterday = (Time.now.utc.to_date - 1).to_s
        today = Time.now.utc.to_date.to_s

        get "/analytics/forms?until=#{yesterday}"
        assert_match(/No form interactions/i, last_response.body)

        get "/analytics/forms?since=#{today}&until=#{today}"
        assert_includes last_response.body, "Per-Field Metrics"
      end

      # Field ids are integers today, but the template escapes them via h.call;
      # this guards that no session-derived string (e.g. metadata stashed by an
      # attacker) is reflected raw, matching the XSS guarantee of every other page.
      def test_forms_escapes_session_html
        seed_form_session("fm-xss", field_ids: [10])
        @store.save_metadata("fm-xss", {"url" => "https://x.test/<script>alert(1)</script>"})

        get "/analytics/forms"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "<script>alert(1)</script>"
      end

      # ── export ──

      # Mirrors how DashboardApp issues a CSRF token: do a GET that sets the
      # sentiero_csrf cookie, then read it back so the POST can echo it.
      def csrf_token_from_index
        get "/analytics/export"
        cookie = last_response.headers["set-cookie"]
        cookie[/sentiero_csrf=([^;]+)/, 1]
      end

      def download(type, format, csrf: :valid)
        token = csrf_token_from_index
        params = {}
        params["csrf_token"] = token if csrf == :valid
        params["csrf_token"] = "deadbeef" if csrf == :invalid
        post "/analytics/export/#{type}.#{format}", params
      end

      def test_export_index_returns_200_with_options
        get "/analytics/export"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Export"
        assert_includes last_response.body, "Session list"
        assert_includes last_response.body, "Error list"
        assert_includes last_response.body, "Form analytics"
      end

      def test_export_index_states_attribution_semantics
        # C2 (P2.2): the export page says how per-URL/entry attribution works.
        get "/analytics/export"

        body = last_response.body
        assert_match(/page on screen when the event\s+happened/i, body)
        assert_match(/first page seen in the recording/i, body)
      end

      def test_export_index_returns_403_when_auth_fails
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/analytics/export"

        assert_equal 403, last_response.status
      end

      def test_export_index_sets_security_headers_and_csrf_cookie
        get "/analytics/export"

        assert_equal "nosniff", last_response.headers["x-content-type-options"]
        assert_includes last_response.headers["set-cookie"], "sentiero_csrf="
        assert_includes last_response.headers["set-cookie"], "HttpOnly"
      end

      def test_sessions_csv_download_returns_403_without_auth
        Sentiero.configuration.auth_callback = ->(_env) { false }

        post "/analytics/export/sessions.csv", {"csrf_token" => "x"}

        assert_equal 403, last_response.status
      end

      def test_sessions_json_download_returns_403_without_auth
        Sentiero.configuration.auth_callback = ->(_env) { false }

        post "/analytics/export/sessions.json", {"csrf_token" => "x"}

        assert_equal 403, last_response.status
      end

      def test_sessions_csv_download_requires_csrf_token
        get "/analytics/export"
        post "/analytics/export/sessions.csv"

        assert_equal 403, last_response.status
      end

      def test_sessions_csv_download_rejects_invalid_csrf_token
        download("sessions", "csv", csrf: :invalid)

        assert_equal 403, last_response.status
      end

      def test_sessions_csv_download_accepts_valid_csrf_token
        download("sessions", "csv")

        assert_equal 200, last_response.status
      end

      def test_sessions_csv_download_returns_text_csv_content_type
        download("sessions", "csv")

        assert_equal "text/csv", last_response.headers["content-type"]
      end

      def test_sessions_csv_download_returns_attachment_header
        download("sessions", "csv")

        assert_includes last_response.headers["content-disposition"], "attachment"
        assert_includes last_response.headers["content-disposition"], "sessions.csv"
      end

      def test_sessions_json_download_returns_application_json_content_type
        download("sessions", "json")

        assert_equal 200, last_response.status
        assert_equal "application/json", last_response.headers["content-type"]
      end

      def test_sessions_json_download_returns_attachment_header
        download("sessions", "json")

        assert_includes last_response.headers["content-disposition"], "attachment"
        assert_includes last_response.headers["content-disposition"], "sessions.json"
      end

      def test_sessions_csv_includes_header_row_and_session_metadata
        download("sessions", "csv")

        assert_includes last_response.body, "session_id"
        assert_includes last_response.body, "sess-1"
        assert_includes last_response.body, "https://example.com/home"
        assert_includes last_response.body, "Chrome"
      end

      def test_sessions_json_includes_session_records
        download("sessions", "json")

        data = JSON.parse(last_response.body)
        assert_includes data.keys, "headers"
        assert_includes data.keys, "rows"
        row = data["rows"].find { |r| r.first == "sess-1" }
        assert row, "expected a row for sess-1"
        assert_includes row, "https://example.com/home"
      end

      def test_unknown_export_dataset_returns_404
        download("bogus", "csv")

        assert_equal 404, last_response.status
      end

      def test_unknown_export_format_returns_404
        token = csrf_token_from_index
        post "/analytics/export/sessions.xml", {"csrf_token" => token}

        assert_equal 404, last_response.status
      end

      # CSV injection: a cell that begins with a formula trigger is prefixed with
      # a single quote so a spreadsheet treats it as text.
      def assert_csv_cell_quoted(dangerous_url)
        @store.save_events(Sentiero::WindowRef.new("danger", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("danger", {"url" => dangerous_url})

        download("sessions", "csv")

        assert_includes last_response.body, "'#{dangerous_url}"
        refute_match(/(^|,)#{Regexp.escape(dangerous_url)}/, last_response.body)
      end

      def test_csv_escapes_equals_prefix
        assert_csv_cell_quoted("=SUM(A1:A9)")
      end

      def test_csv_escapes_plus_prefix
        assert_csv_cell_quoted("+1234567")
      end

      def test_csv_escapes_at_prefix
        assert_csv_cell_quoted("@IMPORTXML(1)")
      end

      def test_csv_escapes_minus_prefix
        # A leading '-' is wrapped, but the wrapped cell contains no comma/quote
        # so it stays unquoted; assert the literal guard prefix is present.
        @store.save_events(Sentiero::WindowRef.new("danger", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("danger", {"url" => "-2+3"})

        download("sessions", "csv")

        assert_includes last_response.body, "'-2+3"
      end

      def test_csv_does_not_escape_normal_cells
        download("sessions", "csv")

        refute_includes last_response.body, "'https://example.com/home"
        assert_includes last_response.body, "https://example.com/home"
      end

      def test_csv_quotes_cells_containing_commas
        @store.save_events(Sentiero::WindowRef.new("comma", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("comma", {"url" => "https://x.test/a,b,c"})

        download("sessions", "csv")

        assert_includes last_response.body, '"https://x.test/a,b,c"'
      end

      def test_errors_csv_download_lists_errors
        seed_error_session("err-1", "w1", {"message" => "Boom happened", "source" => "app.js", "lineno" => 42})

        download("errors", "csv")

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Boom happened"
        assert_includes last_response.body, "app.js"
      end

      def test_browser_events_csv_download_lists_tags
        download("browser_events", "csv")

        assert_equal 200, last_response.status
        assert_includes last_response.body, "click"
      end

      def test_old_custom_events_key_returns_404
        download("custom_events", "csv")

        assert_equal 404, last_response.status
      end

      def test_export_index_lists_browser_events_dataset
        get "/analytics/export"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Browser Events (rrweb)"
        refute_includes last_response.body, "Custom-event list"
      end

      def test_problems_csv_download_lists_seeded_problem
        @store.save_occurrence({
          "fingerprint" => "fp-export-1",
          "project" => "web",
          "exception_class" => "ArgumentError",
          "message" => "wrong number of args",
          "timestamp" => Time.now.to_f
        })

        download("problems", "csv")

        assert_equal 200, last_response.status
        assert_includes last_response.body, "ArgumentError"
        assert_includes last_response.body, "fingerprint"
      end

      def test_server_events_csv_download_lists_seeded_event
        @store.save_server_event({
          "project" => "api",
          "name" => "user.signup",
          "level" => "info",
          "timestamp" => Time.now.to_f,
          "payload" => {"plan" => "pro"}
        })

        download("server_events", "csv")

        assert_equal 200, last_response.status
        assert_includes last_response.body, "user.signup"
        assert_includes last_response.body, "name"
      end

      def test_stats_json_download_returns_aggregates
        download("stats", "json")

        data = JSON.parse(last_response.body)
        assert(data["rows"].any? { |r| r.first == "total_sessions" })
      end

      def test_heatmap_csv_download_lists_clicked_selectors
        seed_heatmap_session("hm-1", url: "https://shop.test/cart")

        download("heatmap", "csv")

        assert_equal 200, last_response.status
        assert_equal "text/csv", last_response.headers["content-type"]
        assert_includes last_response.headers["content-disposition"], "attachment"
        assert_includes last_response.headers["content-disposition"], "heatmap.csv"
        assert_includes last_response.body, "url,selector,count"
        assert_includes last_response.body, "https://shop.test/cart"
        assert_includes last_response.body, "button.add"
      end

      def test_scroll_csv_download_lists_pages
        seed_scroll_session("sc-1", url: "https://shop.test/article")

        download("scroll", "csv")

        assert_equal 200, last_response.status
        assert_equal "text/csv", last_response.headers["content-type"]
        assert_includes last_response.headers["content-disposition"], "attachment"
        assert_includes last_response.headers["content-disposition"], "scroll.csv"
        assert_includes last_response.body, "url,session_count,avg_depth_px"
        assert_includes last_response.body, "https://shop.test/article"
      end

      def test_forms_csv_download_lists_fields
        seed_form_session("fm-1", field_ids: [10, 11])

        download("forms", "csv")

        assert_equal 200, last_response.status
        assert_equal "text/csv", last_response.headers["content-type"]
        assert_includes last_response.headers["content-disposition"], "attachment"
        assert_includes last_response.headers["content-disposition"], "forms.csv"
        assert_includes last_response.body, "field_id,sessions,completion_rate"
        assert_includes last_response.body, "10"
      end

      # ── shareable replays gate ──

      def enable_shareable_replays
        Sentiero.configuration.shareable_replays = true
      end

      def test_share_route_returns_404_when_disabled
        get "/analytics/share/sess-1"

        assert_equal 404, last_response.status
      end

      def test_import_route_returns_404_when_disabled
        get "/analytics/import"

        assert_equal 404, last_response.status
      end

      # ID validation runs before the feature gate, so a malformed id is a 400
      # regardless of whether the feature is enabled.
      def test_share_route_with_invalid_id_returns_400_when_disabled
        get "/analytics/share/bad%20id"

        assert_equal 400, last_response.status
        assert_equal "application/json", last_response.headers["content-type"]
        assert_equal "nosniff", last_response.headers["x-content-type-options"]
      end

      def test_share_route_returns_200_when_enabled
        enable_shareable_replays

        get "/analytics/share/sess-1"

        assert_equal 200, last_response.status
      end

      def test_import_route_returns_200_when_enabled
        enable_shareable_replays

        get "/analytics/import"

        assert_equal 200, last_response.status
      end

      def test_import_route_returns_403_when_auth_fails
        enable_shareable_replays
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/analytics/import"

        assert_equal 403, last_response.status
      end

      def test_import_renders_player_container_and_inputs
        enable_shareable_replays

        get "/analytics/import"

        assert_includes last_response.body, "Import Replay"
        assert_includes last_response.body, 'id="import-player"'
        assert_includes last_response.body, 'id="import-textarea"'
        assert_includes last_response.body, 'id="import-file"'
      end

      def test_import_loads_player_and_import_bundles
        enable_shareable_replays
        get "/analytics/import"

        assert_match(/rrweb-player-[A-Za-z0-9]+\.js/, last_response.body)
        assert_match(/src="[^"]*import-[A-Za-z0-9]+\.js"/, last_response.body)
      end

      def test_import_sets_security_headers_and_csrf_cookie
        enable_shareable_replays

        get "/analytics/import"

        assert_equal "nosniff", last_response.headers["x-content-type-options"]
        assert_equal "DENY", last_response.headers["x-frame-options"]
        assert_includes last_response.headers["set-cookie"], "sentiero_csrf="
        assert_includes last_response.headers["set-cookie"], "HttpOnly"
      end

      # Auth is checked before the feature gate, so an unauthorized request is a
      # 403 even when the feature is enabled (never leaks the feature exists).
      def test_share_route_returns_403_when_auth_fails
        enable_shareable_replays
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/analytics/share/sess-1"

        assert_equal 403, last_response.status
      end

      def test_share_and_import_links_hidden_when_disabled
        get "/analytics/export"

        refute_includes last_response.body, "/analytics/import"
      end

      def test_import_link_shown_when_enabled
        enable_shareable_replays

        get "/analytics/export"

        assert_includes last_response.body, "/analytics/import"
      end

      def test_export_respects_scan_cap
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 1)
        @store.save_events(Sentiero::WindowRef.new("sess-2", "win-1"), [{"type" => 3, "timestamp" => now_ms}])

        download("sessions", "csv")

        assert_equal 200, last_response.status
        # Only the cap's worth of sessions appears: one data row plus the header.
        data_rows = last_response.body.split("\r\n").reject(&:empty?)
        assert_equal 2, data_rows.size
      end

      # ── date-bounded exports ──

      def download_with_range(type, format, since:, until_str:)
        token = csrf_token_from_index
        post "/analytics/export/#{type}.#{format}",
          {"csrf_token" => token, "since" => since, "until" => until_str}
      end

      def test_export_index_renders_date_range_inputs
        get "/analytics/export"

        assert_includes last_response.body, 'name="since"'
        assert_includes last_response.body, 'name="until"'
      end

      def test_export_index_embeds_range_into_download_forms
        get "/analytics/export?since=2026-06-01&until=2026-06-10"

        assert_equal 200, last_response.status
        assert_includes last_response.body, '<input type="hidden" name="since" value="2026-06-01">'
        assert_includes last_response.body, '<input type="hidden" name="until" value="2026-06-10">'
      end

      def test_sessions_export_honors_date_range
        yesterday = (Time.now.utc.to_date - 1).to_s
        today = Time.now.utc.to_date.to_s

        download_with_range("sessions", "csv", since: yesterday, until_str: yesterday)
        refute_includes last_response.body, "sess-1"

        # The To-day is inclusive (regression: until=<today> used to cut at 00:00).
        download_with_range("sessions", "csv", since: today, until_str: today)
        assert_includes last_response.body, "sess-1"
      end

      def test_problems_export_honors_date_range
        @store.save_occurrence({
          "fingerprint" => "fp-range-1",
          "project" => "web",
          "exception_class" => "ArgumentError",
          "message" => "ranged boom",
          "timestamp" => Time.now.to_f
        })
        yesterday = (Time.now.utc.to_date - 1).to_s
        today = Time.now.utc.to_date.to_s

        download_with_range("problems", "csv", since: yesterday, until_str: yesterday)
        refute_includes last_response.body, "ranged boom"

        download_with_range("problems", "csv", since: today, until_str: today)
        assert_includes last_response.body, "ranged boom"
      end

      def test_server_events_export_honors_date_range
        @store.save_server_event({
          "project" => "api", "name" => "ranged.event", "level" => "info",
          "timestamp" => Time.now.to_f, "payload" => {}
        })
        yesterday = (Time.now.utc.to_date - 1).to_s
        today = Time.now.utc.to_date.to_s

        download_with_range("server_events", "csv", since: yesterday, until_str: yesterday)
        refute_includes last_response.body, "ranged.event"

        download_with_range("server_events", "csv", since: today, until_str: today)
        assert_includes last_response.body, "ranged.event"
      end

      def test_export_filename_contains_the_range
        download_with_range("sessions", "csv", since: "2026-06-01", until_str: "2026-06-10")

        assert_includes last_response.headers["content-disposition"],
          "sessions_2026-06-01_to_2026-06-10.csv"
      end

      def test_export_filename_unchanged_without_range
        download("sessions", "csv")

        assert_includes last_response.headers["content-disposition"], '"sessions.csv"'
      end
    end
  end
end
