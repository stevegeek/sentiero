# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/web_vitals_analyzer"

module Sentiero
  module Analytics
    class WebVitalsAnalyzerTest < Minitest::Test
      URL = "https://example.com/product"

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

      # Seeds a session whose window opens with an anchor event (the replay
      # offset reference) followed by one "__perf" custom event per
      # [metric, value, rating] triple, spaced 100ms apart. Field names mirror
      # the recorder verbatim: data.payload {metric, value, rating}.
      def seed_session(session_id, url:, perfs:, window_id: "w1", at: now_ms)
        events = [meta(url, ts: at)]
        perfs.each_with_index do |(metric, value, rating), i|
          events << {"type" => 5, "timestamp" => at + (i + 1) * 100,
                     "data" => {"tag" => "__perf",
                                "payload" => {"metric" => metric, "value" => value, "rating" => rating}}}
        end
        @store.save_events(Sentiero::WindowRef.new(session_id, window_id), events)
        @store.save_metadata(session_id, {"url" => url})
      end

      def analyze(**opts)
        WebVitalsAnalyzer.new(@store).analyze(**opts)
      end

      # ── empty / no samples ──

      def test_empty_store_returns_empty_pages
        result = analyze

        assert_empty result[:pages]
        refute result[:was_truncated]
      end

      def test_session_without_perf_events_is_excluded
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          {"type" => 3, "timestamp" => now_ms},
          {"type" => 5, "timestamp" => now_ms + 1, "data" => {"tag" => "__click", "payload" => {"selector" => "button"}}}
        ])
        @store.save_metadata("s1", {"url" => URL})

        assert_empty analyze[:pages]
      end

      def test_ignores_malformed_perf_payloads
        events = [
          {"type" => 3, "timestamp" => now_ms},
          # value not numeric
          {"type" => 5, "timestamp" => now_ms + 1,
           "data" => {"tag" => "__perf", "payload" => {"metric" => "LCP", "value" => "fast", "rating" => "good"}}},
          # metric not a string
          {"type" => 5, "timestamp" => now_ms + 2,
           "data" => {"tag" => "__perf", "payload" => {"metric" => 7, "value" => 100, "rating" => "good"}}},
          # payload missing entirely
          {"type" => 5, "timestamp" => now_ms + 3, "data" => {"tag" => "__perf"}},
          # not the __perf tag
          {"type" => 5, "timestamp" => now_ms + 4,
           "data" => {"tag" => "perf", "payload" => {"metric" => "LCP", "value" => 100, "rating" => "good"}}}
        ]
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), events)
        @store.save_metadata("s1", {"url" => URL})

        assert_empty analyze[:pages]
      end

      # ── grouping + counts ──

      def test_groups_samples_by_metric
        seed_session("s1", url: URL, perfs: [
          ["LCP", 2400.0, "good"],
          ["CLS", 0.05, "good"],
          ["INP", 350.0, "needs-improvement"]
        ])

        page = analyze[:pages].fetch(URL)

        assert_equal 3, page[:sample_count]
        assert_equal %w[LCP CLS INP].sort, page[:metrics].keys.sort
        assert_equal 1, page[:metrics]["LCP"][:samples]
        assert_equal 1, page[:metrics]["CLS"][:samples]
        assert_equal 1, page[:metrics]["INP"][:samples]
      end

      def test_separates_pages_by_url
        seed_session("a", url: "https://example.com/one", perfs: [["LCP", 1000, "good"]])
        seed_session("b", url: "https://example.com/two", perfs: [["LCP", 5000, "poor"]])

        pages = analyze[:pages]

        assert_equal 2, pages.size
        assert_equal 1000, pages["https://example.com/one"][:metrics]["LCP"][:p50]
        assert_equal 5000, pages["https://example.com/two"][:metrics]["LCP"][:p50]
      end

      def test_sessions_without_url_metadata_are_excluded
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          {"type" => 3, "timestamp" => now_ms},
          {"type" => 5, "timestamp" => now_ms + 1,
           "data" => {"tag" => "__perf", "payload" => {"metric" => "LCP", "value" => 1200, "rating" => "good"}}}
        ])

        assert_empty analyze[:pages]
      end

      def test_url_is_preserved_verbatim_for_template_escaping
        evil = "https://x.test/<script>alert(1)</script>"
        seed_session("s1", url: evil, perfs: [["LCP", 1000, "good"]])

        assert analyze[:pages].key?(evil)
      end

      # ── per-page segmentation (A1): Meta-href boundaries ──

      def meta(href, ts:)
        {"type" => 4, "timestamp" => ts, "data" => {"href" => href, "width" => 1280, "height" => 800}}
      end

      def perf(metric, value, ts:, rating: "good")
        {"type" => 5, "timestamp" => ts,
         "data" => {"tag" => "__perf", "payload" => {"metric" => metric, "value" => value, "rating" => rating}}}
      end

      def test_attributes_samples_to_their_meta_href_segment
        # The S1 ground-truth shape: each page's final LCP report is flushed
        # just before the NEXT page's Meta, so it sits in the segment of the
        # page it measured. Metadata is stuck on the exit page; the samples
        # must not all land there.
        events = [
          meta("https://example.com/", ts: now_ms),
          perf("LCP", 52, ts: now_ms + 10),
          meta("https://example.com/signup", ts: now_ms + 20),
          perf("LCP", 124, ts: now_ms + 30),
          meta("https://example.com/app", ts: now_ms + 40),
          perf("LCP", 96, ts: now_ms + 50)
        ]
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), events)
        @store.save_metadata("s1", {"url" => "https://example.com/app"})

        pages = analyze[:pages]

        assert_equal %w[https://example.com/ https://example.com/app https://example.com/signup],
          pages.keys.sort
        assert_equal 52, pages["https://example.com/"][:metrics]["LCP"][:p50]
        assert_equal 124, pages["https://example.com/signup"][:metrics]["LCP"][:p50]
        assert_equal 96, pages["https://example.com/app"][:metrics]["LCP"][:p50]
      end

      def test_segment_sample_offsets_stay_relative_to_the_window_start
        # Replay deep-links (?t=offset) are relative to the WINDOW's first
        # event — a later segment's sample must not reset the offset base.
        events = [
          meta("https://example.com/", ts: now_ms),
          meta("https://example.com/app", ts: now_ms + 1000),
          perf("LCP", 96, ts: now_ms + 1500)
        ]
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), events)

        worst = analyze[:pages].fetch("https://example.com/app")[:metrics]["LCP"][:worst]

        assert_equal 1500, worst[:offset_ms]
      end

      # ── candidate collapse (A5): one sample per metric per page view ──

      def test_multiple_candidates_within_a_segment_collapse_to_the_last_value
        # web-vitals re-reports LCP while a page is alive (and classic form
        # POSTs reload the same URL, re-emitting per load): a continuous stay
        # on a URL is ONE page-view sample — the final report.
        events = [
          meta("https://example.com/app", ts: now_ms),
          perf("LCP", 96, ts: now_ms + 10),
          meta("https://example.com/app", ts: now_ms + 20),
          perf("LCP", 88, ts: now_ms + 30),
          meta("https://example.com/app", ts: now_ms + 40),
          perf("LCP", 80, ts: now_ms + 50)
        ]
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), events)

        lcp = analyze[:pages].fetch("https://example.com/app")[:metrics]["LCP"]

        assert_equal 1, lcp[:samples]
        assert_equal 80, lcp[:p50]
      end

      def test_s1_ground_truth_yields_one_lcp_sample_per_page_view
        # S1 stored SEVEN LCP reports across /,/signup and five /app reloads;
        # the correct count is 3 — one per continuous page view.
        events = [
          meta("https://example.com/", ts: now_ms), perf("LCP", 52, ts: now_ms + 1),
          meta("https://example.com/signup", ts: now_ms + 10), perf("LCP", 124, ts: now_ms + 11),
          meta("https://example.com/app", ts: now_ms + 20), perf("LCP", 96, ts: now_ms + 21),
          meta("https://example.com/app", ts: now_ms + 30), perf("LCP", 88, ts: now_ms + 31),
          meta("https://example.com/app", ts: now_ms + 40), perf("LCP", 80, ts: now_ms + 41),
          meta("https://example.com/app", ts: now_ms + 50), perf("LCP", 88, ts: now_ms + 51),
          meta("https://example.com/app", ts: now_ms + 60), perf("LCP", 88, ts: now_ms + 61)
        ]
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), events)
        @store.save_metadata("s1", {"url" => "https://example.com/app"})

        pages = analyze[:pages]

        total = pages.values.sum { |page| page[:metrics].fetch("LCP")[:samples] }
        assert_equal 3, total
        assert_equal 52, pages["https://example.com/"][:metrics]["LCP"][:p50]
        assert_equal 124, pages["https://example.com/signup"][:metrics]["LCP"][:p50]
        assert_equal 88, pages["https://example.com/app"][:metrics]["LCP"][:p50]
      end

      def test_each_metric_collapses_independently_within_a_segment
        seed_session("s1", url: URL, perfs: [
          ["LCP", 1000, "good"],
          ["CLS", 0.05, "good"],
          ["LCP", 2400, "needs-improvement"],
          ["CLS", 0.31, "poor"]
        ])

        page = analyze[:pages].fetch(URL)

        assert_equal 1, page[:metrics]["LCP"][:samples]
        assert_equal 2400, page[:metrics]["LCP"][:p50]
        assert_equal 1, page[:metrics]["CLS"][:samples]
        assert_in_delta 0.31, page[:metrics]["CLS"][:p50], 0.001
      end

      def test_collapsed_sample_carries_the_last_candidates_rating
        seed_session("s1", url: URL, perfs: [
          ["LCP", 1000, "good"],
          ["LCP", 6000, "poor"]
        ])

        lcp = analyze[:pages].fetch(URL)[:metrics]["LCP"]

        assert_equal({"poor" => 1}, lcp[:ratings])
      end

      def test_worst_sample_is_tracked_from_collapsed_values_only
        # An early larger candidate is superseded by the final report — it
        # must not survive as the "worst session" deep-link.
        seed_session("slowish", url: URL, perfs: [["LCP", 9000, "poor"], ["LCP", 1000, "good"]])
        seed_session("worst", url: URL, perfs: [["LCP", 5000, "poor"]], window_id: "ww")

        worst = analyze[:pages].fetch(URL)[:metrics]["LCP"][:worst]

        assert_equal "worst", worst[:session_id]
        assert_in_delta 5000.0, worst[:value], 0.01
      end

      def test_revisits_after_another_page_are_separate_samples
        # / -> /app -> / is two page views of /: two samples, not one.
        events = [
          meta("https://example.com/", ts: now_ms), perf("LCP", 50, ts: now_ms + 1),
          meta("https://example.com/app", ts: now_ms + 10), perf("LCP", 90, ts: now_ms + 11),
          meta("https://example.com/", ts: now_ms + 20), perf("LCP", 70, ts: now_ms + 21)
        ]
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), events)

        lcp = analyze[:pages].fetch("https://example.com/")[:metrics]["LCP"]

        assert_equal 2, lcp[:samples]
      end

      # ── percentiles ──

      def test_percentiles_are_nearest_rank_per_metric
        [1000, 2000, 3000, 4000, 5000].each_with_index do |value, i|
          seed_session("s#{i}", url: URL, perfs: [["LCP", value, "good"]])
        end

        lcp = analyze[:pages].fetch(URL)[:metrics]["LCP"]

        # 50th/75th/90th percentile (nearest-rank) of [1000..5000].
        assert_equal 5, lcp[:samples]
        assert_in_delta 3000.0, lcp[:p50], 0.01
        assert_in_delta 4000.0, lcp[:p75], 0.01
        assert_in_delta 5000.0, lcp[:p90], 0.01
      end

      def test_single_sample_percentiles_are_that_sample
        seed_session("s1", url: URL, perfs: [["CLS", 0.31, "poor"]])

        cls = analyze[:pages].fetch(URL)[:metrics]["CLS"]

        assert_in_delta 0.31, cls[:p50], 0.001
        assert_in_delta 0.31, cls[:p75], 0.001
        assert_in_delta 0.31, cls[:p90], 0.001
      end

      # ── rating mix ──

      def test_rating_mix_tallies_stored_ratings_verbatim
        seed_session("s1", url: URL, perfs: [["LCP", 1000, "good"]])
        seed_session("s2", url: URL, perfs: [["LCP", 2000, "good"]])
        seed_session("s3", url: URL, perfs: [["LCP", 6000, "poor"]])
        seed_session("s4", url: URL, perfs: [["LCP", 3000, "needs-improvement"]])
        # No server-side thresholds: an unexpected stored string is kept as-is.
        seed_session("s5", url: URL, perfs: [["LCP", 3000, "mystery"]])
        # A missing rating still counts the sample, but no rating bucket.
        seed_session("s6", url: URL, perfs: [["LCP", 3000, nil]])

        lcp = analyze[:pages].fetch(URL)[:metrics]["LCP"]

        assert_equal 6, lcp[:samples]
        assert_equal 2, lcp[:ratings]["good"]
        assert_equal 1, lcp[:ratings]["needs-improvement"]
        assert_equal 1, lcp[:ratings]["poor"]
        assert_equal 1, lcp[:ratings]["mystery"]
        assert_equal 5, lcp[:ratings].values.sum
      end

      # ── worst (slowest) sessions ──

      def test_worst_session_is_the_highest_value_per_metric
        seed_session("fast", url: URL, perfs: [["LCP", 1200, "good"]], window_id: "wf")
        seed_session("slow", url: URL, perfs: [["LCP", 8200, "poor"]], window_id: "ws")

        worst = analyze[:pages].fetch(URL)[:metrics]["LCP"][:worst]

        assert_equal "slow", worst[:session_id]
        assert_equal "ws", worst[:window_id]
        assert_in_delta 8200.0, worst[:value], 0.01
      end

      def test_worst_session_offset_is_relative_to_window_first_event
        # The single __perf event sits 100ms after the window's anchor event.
        seed_session("s1", url: URL, perfs: [["INP", 900, "poor"]])

        worst = analyze[:pages].fetch(URL)[:metrics]["INP"][:worst]

        assert_equal 100, worst[:offset_ms]
      end

      # ── scan cap / truncation ──

      def test_respects_scan_cap
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 1)
        seed_session("s1", url: URL, perfs: [["LCP", 1000, "good"]])
        seed_session("s2", url: URL, perfs: [["LCP", 2000, "good"]])

        result = analyze

        assert_equal 1, result[:pages].fetch(URL)[:metrics]["LCP"][:samples]
        assert result[:was_truncated]
      end

      def test_explicit_limit_overrides_config
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 5000)
        seed_session("s1", url: URL, perfs: [["LCP", 1000, "good"]])
        seed_session("s2", url: URL, perfs: [["LCP", 2000, "good"]])

        result = analyze(limit: 1)

        assert_equal 1, result[:pages].fetch(URL)[:metrics]["LCP"][:samples]
        assert result[:was_truncated]
      end

      def test_not_truncated_when_under_cap
        seed_session("s1", url: URL, perfs: [["LCP", 1000, "good"]])

        refute analyze[:was_truncated]
      end

      # Truncation must reflect the store scan being capped, even when none of
      # the scanned sessions contributed vitals.
      def test_truncated_when_capped_sessions_lack_perf_data
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_events(Sentiero::WindowRef.new("s2", "w1"), [{"type" => 3, "timestamp" => now_ms}])

        assert analyze(limit: 1)[:was_truncated]
      end

      # ── bounded accumulation ──

      def test_caps_distinct_urls_and_flags_truncation
        (WebVitalsAnalyzer::MAX_URLS + 1).times do |i|
          seed_session("s#{i}", url: "https://example.com/page-#{i}", perfs: [["LCP", 1000, "good"]])
        end

        result = analyze

        assert_equal WebVitalsAnalyzer::MAX_URLS, result[:pages].size
        assert result[:was_truncated]
      end

      def test_caps_samples_per_metric_and_flags_truncation
        # One sample per metric per SEGMENT since the candidate collapse
        # (A5), so the cap needs cap+5 distinct page views of the URL —
        # alternating Metas keep the same-href runs from merging.
        cap = WebVitalsAnalyzer::MAX_SAMPLES_PER_METRIC
        events = (cap + 5).times.flat_map do |i|
          [
            {"type" => 4, "timestamp" => now_ms + i * 3, "data" => {"href" => URL, "width" => 1, "height" => 1}},
            {"type" => 5, "timestamp" => now_ms + i * 3 + 1,
             "data" => {"tag" => "__perf", "payload" => {"metric" => "LCP", "value" => 1000 + i, "rating" => "good"}}},
            {"type" => 4, "timestamp" => now_ms + i * 3 + 2, "data" => {"href" => "#{URL}/other", "width" => 1, "height" => 1}}
          ]
        end
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), events)

        result = analyze

        assert_equal cap, result[:pages].fetch(URL)[:metrics]["LCP"][:samples]
        assert result[:was_truncated]
      end

      # ── since/until_time bounds ──

      def test_analyze_honors_date_bounds
        seed_session("s1", url: URL, perfs: [["LCP", 1000, "good"]])

        out_of_window = analyze(until_time: Time.now.to_f - 3600)
        in_window = analyze(since: Time.now.to_f - 3600, until_time: Time.now.to_f + 3600)

        assert_empty out_of_window[:pages]
        assert in_window[:pages].key?(URL)
      end
    end
  end
end
