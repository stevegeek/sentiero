# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/heatmap_analyzer"

module Sentiero
  module Analytics
    class HeatmapAnalyzerTest < Minitest::Test
      URL = "https://example.com/home"

      def setup
        @store = Stores::Memory.new
        Sentiero.configure do |c|
          c.store = @store
          c.analytics_max_scan_sessions = 5000
        end
      end

      def teardown
        Sentiero.reset_configuration!
      end

      def now_ms
        @now_ms ||= (Time.now.to_f * 1000).round
      end

      # Saves a session on `url` whose window records a meta event (viewport) and
      # a native rrweb click at each [x, y]. When a click carries a selector, a
      # paired "__click" custom event is emitted (the recorder annotation the
      # top-elements aggregation reads).
      def seed_session(session_id, url:, width:, height:, clicks:)
        events = [{"type" => 4, "timestamp" => now_ms, "data" => {"href" => url, "width" => width, "height" => height}}]
        clicks.each_with_index do |(x, y, selector), i|
          ts = now_ms + i + 1
          events << {"type" => 3, "timestamp" => ts, "data" => {"source" => 2, "type" => 2, "x" => x, "y" => y}}
          if selector
            events << {"type" => 5, "timestamp" => ts, "data" => {"tag" => "__click", "payload" => {"selector" => selector}}}
          end
        end
        @store.save_events(Sentiero::WindowRef.new(session_id, "w1"), events)
        @store.save_metadata(session_id, {"url" => url})
      end

      def analyze(url, **opts)
        HeatmapAnalyzer.new(@store).analyze(url, **opts)
      end

      # ── empty / unknown URL ──

      def test_empty_store_returns_empty_result
        result = analyze(URL)

        assert_empty result[:clicks_by_bucket]
        assert_empty result[:top_elements]
        assert_equal 0, result[:total_clicks]
      end

      def test_unknown_url_returns_empty_result
        seed_session("s1", url: URL, width: 1000, height: 1000, clicks: [[100, 100]])

        result = analyze("https://example.com/other")

        assert_empty result[:clicks_by_bucket]
        assert_equal 0, result[:total_clicks]
      end

      # ── aggregation ──

      def test_aggregates_clicks_into_buckets
        # Two clicks in the same 5%-wide bucket, one in another.
        seed_session("s1", url: URL, width: 1000, height: 1000, clicks: [
          [100, 100], # x 10% -> col 2, y 10% -> row 2
          [120, 110], # x 12% -> col 2, y 11% -> row 2
          [500, 500]  # x 50% -> col 10, y 50% -> row 10
        ])

        result = analyze(URL)

        assert_equal 3, result[:total_clicks]
        assert_equal 2, result[:clicks_by_bucket][[2, 2]]
        assert_equal 1, result[:clicks_by_bucket][[10, 10]]
      end

      def test_clicks_outside_viewport_are_clamped
        seed_session("s1", url: URL, width: 1000, height: 1000, clicks: [
          [-50, -50],   # below 0 -> col/row 0
          [5000, 5000]  # above viewport -> last bucket (19)
        ])

        result = analyze(URL)

        assert_equal 1, result[:clicks_by_bucket][[0, 0]]
        assert_equal 1, result[:clicks_by_bucket][[19, 19]]
      end

      # ── viewport normalization (cross-device) ──

      def test_normalizes_clicks_by_viewport_size
        # Same proportional position on two very different viewports lands in the
        # same bucket after normalization.
        seed_session("wide", url: URL, width: 1920, height: 1080, clicks: [[960, 540]])
        seed_session("narrow", url: URL, width: 400, height: 600, clicks: [[200, 300]])

        result = analyze(URL)

        assert_equal 2, result[:total_clicks]
        # Both clicks are at 50% width / 50% height -> bucket [10, 10].
        assert_equal 2, result[:clicks_by_bucket][[10, 10]]
      end

      def test_clicks_without_viewport_metadata_are_skipped
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          {"type" => 3, "timestamp" => now_ms, "data" => {"source" => 2, "type" => 2, "x" => 100, "y" => 100}}
        ])
        @store.save_metadata("s1", {"url" => URL})

        result = analyze(URL)

        assert_empty result[:clicks_by_bucket]
        assert_equal 0, result[:total_clicks]
      end

      # ── non-click events ignored ──

      def test_ignores_non_click_events
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          {"type" => 4, "timestamp" => now_ms, "data" => {"href" => URL, "width" => 1000, "height" => 1000}},
          # scroll (source 3) — ignored
          {"type" => 3, "timestamp" => now_ms + 1, "data" => {"source" => 3, "x" => 100, "y" => 100}},
          # mouse move/other interaction subtype (type 1) — ignored
          {"type" => 3, "timestamp" => now_ms + 2, "data" => {"source" => 2, "type" => 1, "x" => 100, "y" => 100}},
          # a real click
          {"type" => 3, "timestamp" => now_ms + 3, "data" => {"source" => 2, "type" => 2, "x" => 100, "y" => 100}}
        ])
        @store.save_metadata("s1", {"url" => URL})

        result = analyze(URL)

        assert_equal 1, result[:total_clicks]
      end

      # ── top clicked elements ──

      def test_aggregates_top_clicked_elements_by_selector
        seed_session("s1", url: URL, width: 1000, height: 1000, clicks: [
          [10, 10, "button.add"],
          [20, 20, "button.add"],
          [30, 30, "a.link"]
        ])

        result = analyze(URL)
        top = result[:top_elements]

        assert_equal 2, top.size
        assert_equal({selector: "button.add", count: 2}, top.first)
        assert_equal({selector: "a.link", count: 1}, top.last)
      end

      def test_clicks_without_selector_are_excluded_from_top_elements
        seed_session("s1", url: URL, width: 1000, height: 1000, clicks: [
          [10, 10],
          [20, 20, "button.add"]
        ])

        result = analyze(URL)

        assert_equal 1, result[:top_elements].size
        assert_equal "button.add", result[:top_elements].first[:selector]
        # The selector-less click still counts toward the density buckets.
        assert_equal 2, result[:total_clicks]
      end

      # ── representative window for the canvas overlay ──

      def test_reports_a_representative_window_on_the_url
        seed_session("s1", url: URL, width: 1000, height: 1000, clicks: [[10, 10]])

        result = analyze(URL)

        assert_equal({session_id: "s1", window_id: "w1"}, result[:representative_window])
      end

      def test_representative_window_is_nil_for_unknown_url
        result = analyze(URL)

        assert_nil result[:representative_window]
      end

      # ── scan cap ──

      def test_respects_scan_cap
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 1)
        seed_session("s1", url: URL, width: 1000, height: 1000, clicks: [[100, 100]])
        seed_session("s2", url: URL, width: 1000, height: 1000, clicks: [[200, 200]])

        result = analyze(URL)

        assert_equal 1, result[:total_clicks]
        assert result[:was_truncated]
      end

      def test_truncates_on_total_sessions_scanned_not_just_url_matches
        # The cap counts every session scanned, not only those matching the
        # queried URL: two sessions on other pages fill the cap before the one
        # matching session is reached.
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 2)
        seed_session("s1", url: "https://example.com/other", width: 1000, height: 1000, clicks: [[100, 100]])
        seed_session("s2", url: "https://example.com/other", width: 1000, height: 1000, clicks: [[100, 100]])
        seed_session("s3", url: URL, width: 1000, height: 1000, clicks: [[100, 100]])

        assert analyze(URL)[:was_truncated]
      end

      def test_not_truncated_when_under_cap
        seed_session("s1", url: URL, width: 1000, height: 1000, clicks: [[100, 100]])

        refute analyze(URL)[:was_truncated]
      end

      # ── recorded URLs listing (for the picker) ──

      def test_recorded_urls_lists_unique_urls_with_clicks
        seed_session("s1", url: URL, width: 1000, height: 1000, clicks: [[10, 10]])
        seed_session("s2", url: "https://example.com/about", width: 1000, height: 1000, clicks: [[10, 10]])
        seed_session("s3", url: URL, width: 1000, height: 1000, clicks: [[20, 20]])

        urls = HeatmapAnalyzer.new(@store).recorded_urls

        assert_equal ["https://example.com/about", URL], urls.sort
      end

      # ── per-page segmentation (A1): Meta-href boundaries ──

      def meta(href, ts:, width: 1000, height: 1000)
        {"type" => 4, "timestamp" => ts, "data" => {"href" => href, "width" => width, "height" => height}}
      end

      def click_event(x, y, ts:)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 2, "type" => 2, "x" => x, "y" => y}}
      end

      # The S1 ground-truth shape: ONE window spanning / -> /signup -> /app,
      # session metadata stuck on the exit page. Clicks must land on the page
      # they happened on, not all on /app.
      def seed_multi_page_window(session_id = "s1")
        events = [
          meta("https://example.com/", ts: now_ms),
          click_event(100, 100, ts: now_ms + 10),
          meta("https://example.com/signup", ts: now_ms + 20),
          click_event(500, 500, ts: now_ms + 30),
          meta("https://example.com/app", ts: now_ms + 40),
          click_event(900, 900, ts: now_ms + 50),
          click_event(910, 910, ts: now_ms + 60)
        ]
        @store.save_events(Sentiero::WindowRef.new(session_id, "w1"), events)
        @store.save_metadata(session_id, {"url" => "https://example.com/app"})
      end

      def test_attributes_clicks_to_their_meta_href_segment
        seed_multi_page_window

        landing = analyze("https://example.com/")
        signup = analyze("https://example.com/signup")
        app = analyze("https://example.com/app")

        assert_equal 1, landing[:total_clicks]
        assert_equal 1, landing[:clicks_by_bucket][[2, 2]]
        assert_equal 1, signup[:total_clicks]
        assert_equal 1, signup[:clicks_by_bucket][[10, 10]]
        # The exit page no longer absorbs the whole window's clicks.
        assert_equal 2, app[:total_clicks]
      end

      def test_mid_window_pages_are_selectable_even_when_metadata_says_otherwise
        # /signup never appears in any session's metadata url (it is always a
        # pass-through page) — it must still aggregate and be listed.
        seed_multi_page_window

        result = analyze("https://example.com/signup")

        assert_equal 1, result[:total_clicks]
        assert_equal({session_id: "s1", window_id: "w1"}, result[:representative_window])
      end

      def test_selector_annotations_follow_their_segment
        events = [
          meta("https://example.com/", ts: now_ms),
          click_event(10, 10, ts: now_ms + 1),
          {"type" => 5, "timestamp" => now_ms + 1, "data" => {"tag" => "__click", "payload" => {"selector" => "a.hero"}}},
          meta("https://example.com/app", ts: now_ms + 20),
          click_event(20, 20, ts: now_ms + 21),
          {"type" => 5, "timestamp" => now_ms + 21, "data" => {"tag" => "__click", "payload" => {"selector" => "button.todo"}}}
        ]
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), events)
        @store.save_metadata("s1", {"url" => "https://example.com/app"})

        landing = analyze("https://example.com/")
        table = HeatmapAnalyzer.new(@store).build_heatmap_table

        assert_equal [{selector: "a.hero", count: 1}], landing[:top_elements]
        assert_equal [{selector: "a.hero", count: 1}], table["https://example.com/"]
        assert_equal [{selector: "button.todo", count: 1}], table["https://example.com/app"]
      end

      def test_recorded_urls_lists_meta_hrefs_not_just_metadata
        seed_multi_page_window
        # A single-page session contributes its one Meta href.
        seed_session("single", url: "https://example.com/old", width: 1000, height: 1000, clicks: [[10, 10]])

        urls = HeatmapAnalyzer.new(@store).recorded_urls

        assert_equal %w[
          https://example.com/ https://example.com/app
          https://example.com/old https://example.com/signup
        ], urls.sort
      end

      def test_recorded_urls_caps_distinct_urls
        events = (HeatmapAnalyzer::MAX_URLS + 5).times.flat_map do |i|
          [meta("https://example.com/p#{i}", ts: now_ms + i)]
        end
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), events)

        urls = HeatmapAnalyzer.new(@store).recorded_urls

        assert_equal HeatmapAnalyzer::MAX_URLS, urls.size
      end

      def test_build_heatmap_table_caps_distinct_urls
        events = (HeatmapAnalyzer::MAX_URLS + 5).times.flat_map do |i|
          [
            meta("https://example.com/p#{i}", ts: now_ms + i * 2),
            {"type" => 5, "timestamp" => now_ms + i * 2 + 1,
             "data" => {"tag" => "__click", "payload" => {"selector" => "b#{i}"}}}
          ]
        end
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), events)

        table = HeatmapAnalyzer.new(@store).build_heatmap_table

        assert_equal HeatmapAnalyzer::MAX_URLS, table.size
      end

      # ── page-relative normalization (A2): scroll offset + page height ──

      def scroll_event(y, ts:, id: 1)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 3, "id" => id, "x" => 0, "y" => y}}
      end

      def test_clicks_are_normalized_to_page_coordinates_not_viewport
        # The S1 ground-truth flip: footer CTA clicked at viewport (640,606)
        # after scrolling to 2469 on a 1280x800 viewport. Page height
        # estimate = max scroll + viewport = 3269; page-y = 606+2469 = 3075
        # (~94% of the page) -> row 18, NOT the 75-80% viewport band (row 15).
        events = [
          meta("https://example.com/", ts: now_ms, width: 1280, height: 800),
          scroll_event(1234, ts: now_ms + 10),
          scroll_event(2469, ts: now_ms + 20),
          click_event(640, 606, ts: now_ms + 30)
        ]
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), events)
        @store.save_metadata("s1", {"url" => "https://example.com/"})

        result = analyze("https://example.com/")

        assert_equal 1, result[:total_clicks]
        assert_equal 1, result[:clicks_by_bucket][[10, 18]]
        assert_empty result[:clicks_by_bucket].keys.select { |(_col, row)| row == 15 }
      end

      def test_click_above_the_fold_after_scrolling_back_lands_near_the_top
        # Scrolled deep (page height grows), then back near the top: the
        # click's page position uses the LATEST scroll offset, the page
        # height keeps the maximum.
        events = [
          meta("https://example.com/", ts: now_ms, width: 1280, height: 800),
          scroll_event(2469, ts: now_ms + 10),
          scroll_event(68, ts: now_ms + 20),
          click_event(716, 400, ts: now_ms + 30)
        ]
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), events)
        @store.save_metadata("s1", {"url" => "https://example.com/"})

        result = analyze("https://example.com/")

        # page-y = 400+68 = 468 of 3269 (~14%) -> row 2.
        assert_equal 1, result[:clicks_by_bucket][[11, 2]]
      end

      def test_unscrolled_pages_fall_back_to_viewport_height
        seed_session("s1", url: URL, width: 1000, height: 1000, clicks: [[500, 500]])

        result = analyze(URL)

        assert_equal 1, result[:clicks_by_bucket][[10, 10]]
      end

      def test_scroll_offset_resets_on_same_page_reload
        # A same-href Meta (form POST reload) resets the document scroll to
        # 0 even though the segment continues — a click right after the
        # reload is back at the top of the page.
        events = [
          meta("https://example.com/app", ts: now_ms, width: 1000, height: 1000),
          scroll_event(1000, ts: now_ms + 10),
          meta("https://example.com/app", ts: now_ms + 20, width: 1000, height: 1000),
          click_event(100, 100, ts: now_ms + 30)
        ]
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), events)

        result = analyze("https://example.com/app")

        # Page height = 1000 (max scroll) + 1000 (viewport) = 2000;
        # page-y = 100 + 0 (reset) = 100 -> row 1. Without the reset the
        # click would sit at 1100/2000 -> row 11.
        assert_equal 1, result[:clicks_by_bucket][[2, 1]]
      end

      def test_nested_element_scrolls_do_not_shift_clicks
        # Source-3 events on non-root nodes (id != 1) are element scrolls
        # (lists, modals) — they must affect neither the offset nor the
        # page-height estimate.
        events = [
          meta("https://example.com/", ts: now_ms, width: 1000, height: 1000),
          scroll_event(5000, ts: now_ms + 10, id: 42),
          click_event(500, 500, ts: now_ms + 20)
        ]
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), events)
        @store.save_metadata("s1", {"url" => "https://example.com/"})

        result = analyze("https://example.com/")

        assert_equal 1, result[:clicks_by_bucket][[10, 10]]
      end

      # ── since/until_time bounds ──

      def test_analyze_honors_date_bounds
        seed_session("s1", url: URL, width: 1000, height: 1000, clicks: [[100, 100]])

        out_of_window = analyze(URL, until_time: Time.now.to_f - 3600)
        in_window = analyze(URL, since: Time.now.to_f - 3600, until_time: Time.now.to_f + 3600)

        assert_equal 0, out_of_window[:total_clicks]
        assert_equal 1, in_window[:total_clicks]
      end

      def test_build_heatmap_table_honors_date_bounds
        seed_session("s1", url: URL, width: 1000, height: 1000, clicks: [[100, 100, "button.buy"]])

        out_of_window = HeatmapAnalyzer.new(@store).build_heatmap_table(until_time: Time.now.to_f - 3600)
        in_window = HeatmapAnalyzer.new(@store).build_heatmap_table(since: Time.now.to_f - 3600)

        assert_empty out_of_window
        assert_equal "button.buy", in_window[URL].first[:selector]
      end
    end
  end
end
