# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/scroll_depth_analyzer"

module Sentiero
  module Analytics
    class ScrollDepthAnalyzerTest < Minitest::Test
      URL = "https://example.com/article"

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

      # Seeds a session whose window records a meta event (viewport height) and a
      # scroll (type 3 / source 3) event for each y offset in `scrolls`.
      def seed_session(session_id, url:, height:, scrolls:, window_id: "w1")
        events = [{"type" => 4, "timestamp" => now_ms, "data" => {"href" => url, "width" => 1000, "height" => height}}]
        scrolls.each_with_index do |y, i|
          events << {"type" => 3, "timestamp" => now_ms + i + 1, "data" => {"source" => 3, "id" => 1, "x" => 0, "y" => y}}
        end
        @store.save_events(Sentiero::WindowRef.new(session_id, window_id), events)
        @store.save_metadata(session_id, {"url" => url})
      end

      def analyze(**opts)
        ScrollDepthAnalyzer.new(@store).analyze(**opts)
      end

      # ── empty / no scrolls ──

      def test_empty_store_returns_empty_pages
        result = analyze

        assert_empty result[:pages]
        refute result[:was_truncated]
      end

      # Regression: was_truncated counts DISTINCT sessions, not windows, so one
      # session spanning several windows can't trip the scan cap on its own.
      def test_was_truncated_counts_sessions_not_windows
        seed_session("s1", url: URL, height: 600, scrolls: [300], window_id: "w1")
        seed_session("s1", url: URL, height: 600, scrolls: [400], window_id: "w2")

        refute analyze(limit: 2)[:was_truncated]
      end

      def test_session_without_scroll_events_is_excluded
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          {"type" => 4, "timestamp" => now_ms, "data" => {"width" => 1000, "height" => 800}},
          {"type" => 3, "timestamp" => now_ms + 1, "data" => {"source" => 2, "type" => 2, "x" => 1, "y" => 1}}
        ])
        @store.save_metadata("s1", {"url" => URL})

        assert_empty analyze[:pages]
      end

      def test_zero_scroll_offset_is_ignored
        seed_session("s1", url: URL, height: 800, scrolls: [0])

        assert_empty analyze[:pages]
      end

      # ── single page aggregation ──

      def test_single_session_reports_average_depth
        # max y = 1000, viewport 800 -> the viewport bottom reached
        # (1000 + 800) = 1800px; with one session the estimated page height
        # is that same 1800px, so the session read 100% of the page.
        seed_session("s1", url: URL, height: 800, scrolls: [200, 1000, 600])

        page = analyze[:pages].fetch(URL)

        assert_equal 1, page[:session_count]
        assert_in_delta 1000.0, page[:avg_depth_px], 0.01
        assert_equal 1800, page[:page_height_px]
        assert_in_delta 100.0, page[:avg_depth_pct], 0.01
      end

      def test_fold_lines_are_percentiles_of_absolute_page_pct
        # Five sessions, viewport 1000, max y 1000..5000 -> viewport bottoms
        # 2000..6000; page height estimate = 6000, so the page percentages
        # are 33.3, 50, 66.7, 83.3, 100.
        [1000, 2000, 3000, 4000, 5000].each_with_index do |y, i|
          seed_session("s#{i}", url: URL, height: 1000, scrolls: [y])
        end

        folds = analyze[:pages].fetch(URL)[:fold_lines]

        # 50th/75th/90th percentile (nearest-rank) of the page percentages.
        assert_in_delta 66.67, folds[:p50], 0.01
        assert_in_delta 83.33, folds[:p75], 0.01
        assert_in_delta 100.0, folds[:p90], 0.01
      end

      def test_distribution_histogram_buckets_sum_to_session_count
        # Absolute page percentages fall into the four bins: bottoms
        # 2000/3000/4000/5000 of a 5000px page -> 40, 60, 80, 100%.
        [1000, 2000, 3000, 4000].each_with_index do |y, i|
          seed_session("s#{i}", url: URL, height: 1000, scrolls: [y])
        end

        dist = analyze[:pages].fetch(URL)[:distribution]

        assert_equal 4, dist.values.sum
        assert_equal %w[0-25 25-50 50-75 75-100], dist.keys
        assert_equal({"0-25" => 0, "25-50" => 1, "50-75" => 1, "75-100" => 2}, dist)
      end

      def test_deepest_session_lands_in_top_bucket
        seed_session("shallow", url: URL, height: 1000, scrolls: [100])
        seed_session("deep", url: URL, height: 1000, scrolls: [9000])

        dist = analyze[:pages].fetch(URL)[:distribution]

        assert_equal 1, dist["75-100"]
        # 1100px of a 10000px page is 11% — a shallow bounce must no longer
        # render in the same bin as a read-through.
        assert_equal 1, dist["0-25"]
      end

      def test_ground_truth_bounce_and_readthrough_land_in_different_bins
        # The S1/S2 shape on /: S1 scrolled to 2469 (viewport 800 ->
        # bottom 3269 = the page height estimate, 100%); S2 bounced at 980
        # (bottom 1780 -> 54%). The old deepest-relative scheme put both in
        # 75-100%.
        seed_session("s1", url: URL, height: 800, scrolls: [1234, 2469])
        seed_session("s2", url: URL, height: 800, scrolls: [980])

        page = analyze[:pages].fetch(URL)

        assert_equal 3269, page[:page_height_px]
        assert_equal 1, page[:distribution]["75-100"]
        assert_equal 1, page[:distribution]["50-75"]
        folds = page[:fold_lines]
        assert_in_delta 54.45, folds[:p50], 0.01
        assert_in_delta 100.0, folds[:p90], 0.01
      end

      # ── multiple pages ──

      def test_separates_pages_by_url
        seed_session("a", url: "https://example.com/one", height: 800, scrolls: [400])
        seed_session("b", url: "https://example.com/two", height: 800, scrolls: [800])

        pages = analyze[:pages]

        assert_equal 2, pages.size
        assert pages.key?("https://example.com/one")
        assert pages.key?("https://example.com/two")
      end

      def test_aggregates_multiple_sessions_on_same_url
        seed_session("a", url: URL, height: 1000, scrolls: [1000])
        seed_session("b", url: URL, height: 1000, scrolls: [3000])

        page = analyze[:pages].fetch(URL)

        assert_equal 2, page[:session_count]
        assert_in_delta 2000.0, page[:avg_depth_px], 0.01
      end

      # ── missing viewport ──

      def test_missing_viewport_yields_depth_px_only
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          {"type" => 4, "timestamp" => now_ms, "data" => {"href" => URL}},
          {"type" => 3, "timestamp" => now_ms + 1, "data" => {"source" => 3, "x" => 0, "y" => 1500}}
        ])

        page = analyze[:pages].fetch(URL)

        assert_equal 1, page[:session_count]
        assert_in_delta 1500.0, page[:avg_depth_px], 0.01
        # Without a viewport no page height can be estimated: no percentage.
        assert_nil page[:avg_depth_pct]
        assert_nil page[:page_height_px]
        assert_nil page[:fold_lines][:p50]
      end

      def test_viewport_less_sessions_bin_relative_to_the_deepest_pixels
        # Degraded mode for viewport-less recordings: no percentage is
        # derivable, so the histogram falls back to depth relative to the
        # deepest session — sessions still land somewhere instead of
        # disappearing from the distribution.
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          {"type" => 4, "timestamp" => now_ms, "data" => {"href" => URL}},
          {"type" => 3, "timestamp" => now_ms + 1, "data" => {"source" => 3, "x" => 0, "y" => 4000}}
        ])
        @store.save_events(Sentiero::WindowRef.new("s2", "w1"), [
          {"type" => 4, "timestamp" => now_ms, "data" => {"href" => URL}},
          {"type" => 3, "timestamp" => now_ms + 1, "data" => {"source" => 3, "x" => 0, "y" => 500}}
        ])

        dist = analyze[:pages].fetch(URL)[:distribution]

        assert_equal 2, dist.values.sum
        assert_equal 1, dist["75-100"]
        assert_equal 1, dist["0-25"]
      end

      # ── url handling ──

      def test_sessions_without_url_metadata_are_excluded
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          {"type" => 4, "timestamp" => now_ms, "data" => {"width" => 1000, "height" => 800}},
          {"type" => 3, "timestamp" => now_ms + 1, "data" => {"source" => 3, "x" => 0, "y" => 500}}
        ])

        assert_empty analyze[:pages]
      end

      def test_url_is_preserved_verbatim_for_template_escaping
        evil = "https://x.test/<script>alert(1)</script>"
        seed_session("s1", url: evil, height: 800, scrolls: [400])

        assert analyze[:pages].key?(evil)
      end

      # ── per-page segmentation (A1): Meta-href boundaries ──

      def meta(href, ts:, height: 800)
        {"type" => 4, "timestamp" => ts, "data" => {"href" => href, "width" => 1000, "height" => height}}
      end

      def scroll_event(y, ts:)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 3, "id" => 1, "x" => 0, "y" => y}}
      end

      def test_attributes_scrolls_to_their_meta_href_segment
        # The S1 ground-truth shape: the landing-page scroll happens before
        # the /signup and /app Metas; metadata is stuck on the exit page. The
        # scroll must build a / row — and must NOT invent an /app row.
        events = [
          meta("https://example.com/", ts: now_ms),
          scroll_event(2469, ts: now_ms + 10),
          meta("https://example.com/signup", ts: now_ms + 20),
          meta("https://example.com/app", ts: now_ms + 40)
        ]
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), events)
        @store.save_metadata("s1", {"url" => "https://example.com/app"})

        pages = analyze[:pages]

        assert_equal ["https://example.com/"], pages.keys
        assert_in_delta 2469.0, pages["https://example.com/"][:avg_depth_px], 0.01
      end

      def test_same_url_segments_in_one_window_count_once_with_deepest_scroll
        # /app reloads on every todo POST: one session, one /app row entry,
        # deepest scroll wins.
        events = [
          meta("https://example.com/app", ts: now_ms),
          scroll_event(300, ts: now_ms + 1),
          meta("https://example.com/app", ts: now_ms + 10),
          scroll_event(150, ts: now_ms + 11)
        ]
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), events)

        page = analyze[:pages].fetch("https://example.com/app")

        assert_equal 1, page[:session_count]
        assert_in_delta 300.0, page[:avg_depth_px], 0.01
      end

      def test_caps_distinct_urls_and_flags_truncation
        events = (ScrollDepthAnalyzer::MAX_URLS + 5).times.flat_map do |i|
          [meta("https://example.com/p#{i}", ts: now_ms + i * 2),
            scroll_event(100, ts: now_ms + i * 2 + 1)]
        end
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), events)

        result = analyze

        assert_equal ScrollDepthAnalyzer::MAX_URLS, result[:pages].size
        assert result[:was_truncated]
      end

      # ── scan cap ──

      def test_respects_scan_cap
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 1)
        seed_session("s1", url: URL, height: 800, scrolls: [400])
        seed_session("s2", url: URL, height: 800, scrolls: [800])

        result = analyze

        assert_equal 1, result[:pages].fetch(URL)[:session_count]
        assert result[:was_truncated]
      end

      def test_explicit_limit_overrides_config
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 5000)
        seed_session("s1", url: URL, height: 800, scrolls: [400])
        seed_session("s2", url: URL, height: 800, scrolls: [800])

        result = analyze(limit: 1)

        assert_equal 1, result[:pages].fetch(URL)[:session_count]
        assert result[:was_truncated]
      end

      def test_not_truncated_when_under_cap
        seed_session("s1", url: URL, height: 800, scrolls: [400])

        refute analyze[:was_truncated]
      end

      # Truncation must reflect the store scan being capped, even when none of the
      # scanned sessions contributed scroll data (no URL or zero scroll depth).
      def test_truncated_when_capped_sessions_lack_scroll_data
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_events(Sentiero::WindowRef.new("s2", "w1"), [{"type" => 3, "timestamp" => now_ms}])

        assert analyze(limit: 1)[:was_truncated]
      end

      # ── since/until_time bounds ──

      def test_analyze_honors_date_bounds
        seed_session("s1", url: URL, height: 800, scrolls: [1500])

        out_of_window = analyze(until_time: Time.now.to_f - 3600)
        in_window = analyze(since: Time.now.to_f - 3600, until_time: Time.now.to_f + 3600)

        assert_empty out_of_window[:pages]
        assert in_window[:pages].key?(URL)
      end
    end
  end
end
