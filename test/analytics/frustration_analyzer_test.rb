# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/frustration_analyzer"
require "sentiero/analytics/frustration/detectors"

module Sentiero
  module Analytics
    class FrustrationAnalyzerTest < Minitest::Test
      URL = "https://example.com/checkout"

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

      # ── event builders (mirror frontend/test/frustration_test.js) ──

      # rrweb left-click mouse-interaction at (x, y).
      def click(ts, x, y)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 2, "type" => 2, "x" => x, "y" => y}}
      end

      def mutation(ts)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 0, "adds" => [], "removes" => [], "attributes" => [], "texts" => []}}
      end

      def input(ts)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 5, "text" => "x"}}
      end

      # The recorder's "__click" selector annotation (heatmap_analyzer reads the
      # same events for its top-elements table).
      def click_annotation(ts, selector)
        {"type" => 5, "timestamp" => ts, "data" => {"tag" => "__click", "payload" => {"selector" => selector}}}
      end

      # ══════════════════════════════════════════════════════════════════
      # Detector ports — every case below is a 1:1 port of a JS test in
      # frontend/test/frustration_test.js, pinning the Ruby detectors to the
      # client implementation (same thresholds, same semantics).
      # ══════════════════════════════════════════════════════════════════

      def test_constants_match_the_js_detectors
        assert_equal 500, Frustration::Detectors::RAGE_WINDOW_MS
        assert_equal 10, Frustration::Detectors::RAGE_COORD_TOLERANCE_PX
        assert_equal 3, Frustration::Detectors::RAGE_MIN_CLICKS
        assert_equal 500, Frustration::Detectors::DEAD_WINDOW_MS
      end

      # ── detectRageClicks ──

      def test_detect_rage_clicks_returns_empty_when_there_are_no_clicks
        assert_empty Frustration::Detectors.detect_rage_clicks([mutation(0), input(10)])
      end

      def test_detect_rage_clicks_returns_empty_for_empty_or_invalid_input
        assert_empty Frustration::Detectors.detect_rage_clicks([])
        assert_empty Frustration::Detectors.detect_rage_clicks(nil)
      end

      def test_detect_rage_clicks_flags_3_clicks_within_500ms_at_same_coords
        events = [click(0, 100, 100), click(100, 102, 99), click(200, 98, 101)]

        out = Frustration::Detectors.detect_rage_clicks(events)

        assert_equal 1, out.length
        assert_equal "rage_click", out[0][:subtype]
        assert_equal 3, out[0][:count]
        assert_equal 0, out[0][:timestamp]
      end

      def test_detect_rage_clicks_does_not_flag_exactly_2_clicks
        events = [click(0, 100, 100), click(100, 100, 100)]

        assert_empty Frustration::Detectors.detect_rage_clicks(events)
      end

      def test_detect_rage_clicks_ignores_clicks_more_than_500ms_apart
        # gaps of 600ms between each -> never 3 within a 500ms window
        events = [click(0, 100, 100), click(600, 100, 100), click(1200, 100, 100)]

        assert_empty Frustration::Detectors.detect_rage_clicks(events)
      end

      def test_detect_rage_clicks_ignores_clicks_more_than_10px_apart
        events = [click(0, 100, 100), click(100, 200, 100), click(200, 300, 100)]

        assert_empty Frustration::Detectors.detect_rage_clicks(events)
      end

      def test_detect_rage_clicks_counts_a_long_burst_as_a_single_rage_cluster
        events = [
          click(0, 50, 50),
          click(100, 51, 50),
          click(200, 50, 51),
          click(300, 52, 50)
        ]

        out = Frustration::Detectors.detect_rage_clicks(events)

        assert_equal 1, out.length
        assert_equal 4, out[0][:count]
      end

      def test_detect_rage_clicks_does_not_flag_a_burst_that_spans_more_than_500ms
        # ~499ms per-pair gaps stay under the per-pair limit, but the cluster
        # span (998ms) exceeds the 500ms window — must not be reported.
        events = [click(0, 10, 10), click(499, 10, 10), click(998, 10, 10)]

        assert_empty Frustration::Detectors.detect_rage_clicks(events)
      end

      def test_detect_rage_clicks_works_with_non_click_events_interleaved
        events = [
          click(0, 10, 10),
          mutation(50),
          click(100, 11, 10),
          input(150),
          click(200, 10, 11)
        ]

        out = Frustration::Detectors.detect_rage_clicks(events)

        assert_equal 1, out.length
        assert_equal 3, out[0][:count]
      end

      # ── detectDeadClicks ──

      def test_detect_dead_clicks_returns_empty_when_there_are_no_clicks
        assert_empty Frustration::Detectors.detect_dead_clicks([mutation(0), input(10)])
      end

      def test_detect_dead_clicks_flags_a_click_with_no_mutation_within_500ms
        events = [click(0, 5, 5), mutation(800)]

        out = Frustration::Detectors.detect_dead_clicks(events)

        assert_equal 1, out.length
        assert_equal "dead_click", out[0][:subtype]
        assert_equal 0, out[0][:timestamp]
      end

      def test_detect_dead_clicks_does_not_flag_a_click_followed_by_a_mutation_within_500ms
        events = [click(0, 5, 5), mutation(300)]

        assert_empty Frustration::Detectors.detect_dead_clicks(events)
      end

      def test_detect_dead_clicks_treats_a_mutation_at_exactly_500ms_as_responsive
        events = [click(0, 5, 5), mutation(500)]

        assert_empty Frustration::Detectors.detect_dead_clicks(events)
      end

      def test_detect_dead_clicks_does_not_flag_a_click_followed_by_input_within_500ms
        events = [click(0, 5, 5), input(100)]

        assert_empty Frustration::Detectors.detect_dead_clicks(events)
      end

      def test_detect_dead_clicks_flags_the_last_click_when_nothing_follows
        events = [mutation(0), click(1000, 5, 5)]

        out = Frustration::Detectors.detect_dead_clicks(events)

        assert_equal 1, out.length
        assert_equal "dead_click", out[0][:subtype]
      end

      # ── detectFrustrationEvents ──

      def test_detect_frustration_events_returns_shaped_offset_sorted_entries
        events = [
          mutation(0),
          # rage burst at ts 1000..1200
          click(1000, 100, 100),
          click(1100, 101, 100),
          click(1200, 100, 101),
          mutation(1250),
          # dead click at ts 5000, no mutation within 500ms
          click(5000, 300, 300),
          mutation(5800)
        ]

        out = Frustration::Detectors.detect_frustration_events(events)

        assert_equal 2, out.length
        out.each do |e|
          assert_equal "frustration", e[:category]
          assert_kind_of Numeric, e[:offset]
          assert e[:event]
        end
        # offsets are relative to the first event timestamp (0), sorted ascending
        assert_equal "rage_click", out[0][:subtype]
        assert_equal 1000, out[0][:offset]
        assert_equal "dead_click", out[1][:subtype]
        assert_equal 5000, out[1][:offset]
      end

      def test_detect_frustration_events_does_not_double_report_rage_cluster_clicks_as_dead
        # 3 rage clicks with no following mutation: one rage entry, not three
        # dead-click entries on top.
        events = [click(0, 10, 10), click(100, 10, 10), click(200, 10, 10)]

        out = Frustration::Detectors.detect_frustration_events(events)

        assert_equal 1, out.count { |e| e[:subtype] == "rage_click" }
        assert_equal 0, out.count { |e| e[:subtype] == "dead_click" }
      end

      # FrustrationAnalyzer.detect_frustration_events stays as a thin class-method
      # delegate — EngagementAnalyzer and PageReportAnalyzer call it directly for
      # raw detection without the cross-session aggregation below.
      def test_class_method_delegates_to_the_detectors_module
        events = [click(0, 10, 10), click(100, 10, 10), click(200, 10, 10)]

        assert_equal Frustration::Detectors.detect_frustration_events(events), FrustrationAnalyzer.detect_frustration_events(events)
      end

      # ══════════════════════════════════════════════════════════════════
      # Cross-session aggregation
      # ══════════════════════════════════════════════════════════════════

      def now_ms
        @now_ms ||= (Time.now.to_f * 1000).round
      end

      def save_session(session_id, url, events, window_id: "w1")
        # Real windows open with a Meta href; prepend one (carrying the page
        # url) unless the test already supplies its own Meta boundaries.
        events = [meta(url, events.first&.fetch("timestamp", now_ms))] + events if url && events.none? { |e| e["type"] == 4 }
        @store.save_events(Sentiero::WindowRef.new(session_id, window_id), events)
        @store.save_metadata(session_id, {"url" => url}) if url
      end

      # A rage burst (3 clicks, 100ms apart) at (x, y) starting at ts, annotated
      # with the recorder's "__click" selector when given.
      def rage_burst(ts, x: 10, y: 10, selector: nil)
        events = [click(ts, x, y), click(ts + 100, x, y), click(ts + 200, x, y)]
        events << click_annotation(ts, selector) if selector
        events
      end

      def analyze(**opts)
        FrustrationAnalyzer.new(@store).analyze(**opts)
      end

      def test_empty_store_returns_empty_pages
        result = analyze

        assert_empty result[:pages]
        refute result[:was_truncated]
      end

      def test_sessions_without_frustration_are_excluded
        save_session("calm", URL, [click(now_ms, 5, 5), mutation(now_ms + 100)])

        assert_empty analyze[:pages]
      end

      def test_sessions_without_url_metadata_are_excluded
        save_session("no-url", nil, [click(now_ms, 5, 5)])

        assert_empty analyze[:pages]
      end

      def test_aggregates_rage_and_dead_counts_per_url
        # One rage burst (responded to, so its clicks are not dead) + one dead
        # click later in the same window.
        save_session("s1", URL, rage_burst(now_ms) + [mutation(now_ms + 300), click(now_ms + 5000, 300, 300)])

        page = analyze[:pages].fetch(URL)

        assert_equal 1, page[:rage_count]
        assert_equal 1, page[:dead_count]
        assert_equal 1, page[:sessions_affected]
      end

      def test_counts_sessions_affected_per_url
        save_session("s1", URL, [click(now_ms, 5, 5)])
        save_session("s2", URL, [click(now_ms, 6, 6)])
        save_session("s3", "https://example.com/other", [click(now_ms, 7, 7)])

        pages = analyze[:pages]

        assert_equal 2, pages.fetch(URL)[:sessions_affected]
        assert_equal 2, pages.fetch(URL)[:dead_count]
        assert_equal 1, pages.fetch("https://example.com/other")[:sessions_affected]
      end

      def test_rage_burst_is_not_double_counted_as_dead_clicks
        save_session("s1", URL, rage_burst(now_ms))

        page = analyze[:pages].fetch(URL)

        assert_equal 1, page[:rage_count]
        assert_equal 0, page[:dead_count]
      end

      def test_top_selectors_cluster_rage_to_nearest_click_annotation
        save_session("s1", URL, rage_burst(now_ms, selector: "button#buy"))
        save_session("s2", URL, rage_burst(now_ms, selector: "button#buy"))
        save_session("s3", URL, rage_burst(now_ms, selector: "a.help"))

        top = analyze[:pages].fetch(URL)[:top_selectors]

        assert_equal [{selector: "button#buy", count: 2}, {selector: "a.help", count: 1}], top
      end

      def test_selector_clustering_requires_a_nearby_click_annotation
        # The only "__click" annotation is 10s away from the rage burst — too
        # far to attribute, so the burst stays selector-less.
        events = rage_burst(now_ms) + [click_annotation(now_ms + 10_000, "button#far")]
        save_session("s1", URL, events)

        page = analyze[:pages].fetch(URL)

        assert_equal 1, page[:rage_count]
        assert_empty page[:top_selectors]
      end

      def test_incidents_carry_replay_coordinates
        # Window anchored 1000ms before the dead click, so its replay offset is 1000.
        save_session("s1", URL, [mutation(now_ms), click(now_ms + 1000, 5, 5)], window_id: "w7")

        incident = analyze[:pages].fetch(URL)[:incidents].first

        assert_equal "dead_click", incident[:subtype]
        assert_equal "s1", incident[:session_id]
        assert_equal "w7", incident[:window_id]
        assert_equal 1000, incident[:offset_ms]
      end

      def test_rage_incidents_carry_count_and_selector
        save_session("s1", URL, rage_burst(now_ms, selector: "button#buy"))

        incident = analyze[:pages].fetch(URL)[:incidents].first

        assert_equal "rage_click", incident[:subtype]
        assert_equal 3, incident[:count]
        assert_equal "button#buy", incident[:selector]
      end

      def test_url_is_preserved_verbatim_for_template_escaping
        evil = "https://x.test/<script>alert(1)</script>"
        save_session("s1", evil, [click(now_ms, 5, 5)])

        assert analyze[:pages].key?(evil)
      end

      # ── per-page segmentation (A1): Meta-href boundaries ──

      def meta(href, ts)
        {"type" => 4, "timestamp" => ts, "data" => {"href" => href, "width" => 1280, "height" => 800}}
      end

      def test_attributes_incidents_to_their_meta_href_segment
        # The S2-meets-S1 shape: a rage burst + dead click on the LANDING
        # page of a window that later navigates on; metadata is stuck on the
        # exit page. The incidents belong to /. (A trailing click follows the
        # dead one so it is not the segment-final click — that one is
        # excluded as likely-navigation by the A4 de-noise layer.)
        events = [meta("https://example.com/", now_ms)] +
          rage_burst(now_ms + 100, selector: "button.demo") +
          [click(now_ms + 5000, 300, 300), click(now_ms + 19_000, 310, 310)] +
          [meta("https://example.com/app", now_ms + 20_000), mutation(now_ms + 20_100)]
        save_session("s1", "https://example.com/app", events)

        pages = analyze[:pages]

        assert_equal ["https://example.com/"], pages.keys
        assert_equal 1, pages["https://example.com/"][:rage_count]
        assert_equal 1, pages["https://example.com/"][:dead_count]
      end

      def test_incident_offsets_stay_relative_to_the_window_start
        # Replay deep-links are relative to the WINDOW's first event, not to
        # the segment the incident landed in.
        events = [
          meta("https://example.com/", now_ms),
          meta("https://example.com/app", now_ms + 10_000),
          click(now_ms + 11_000, 5, 5),
          mutation(now_ms + 12_500)
        ]
        save_session("s1", nil, events)

        incident = analyze[:pages].fetch("https://example.com/app")[:incidents].first

        assert_equal 11_000, incident[:offset_ms]
      end

      def test_sessions_affected_counts_only_pages_with_incidents
        # One session, incidents on / only: /app gets no row at all.
        events = [meta("https://example.com/", now_ms)] +
          rage_burst(now_ms + 100) +
          [meta("https://example.com/app", now_ms + 5000), mutation(now_ms + 5100)]
        save_session("s1", nil, events)

        pages = analyze[:pages]

        assert_equal 1, pages.fetch("https://example.com/")[:sessions_affected]
        refute pages.key?("https://example.com/app")
      end

      # ── dead-click de-noising (A4): layered on top of the pure detectors ──

      def custom_event(ts, tag, payload = {})
        {"type" => 5, "timestamp" => ts, "data" => {"tag" => tag, "payload" => payload}}
      end

      def test_custom_events_within_the_response_window_count_as_responses
        # The S3 external-link shape: the click fires a `navigation` custom
        # in the same tick, then the window ends (the page unloaded). The
        # pure detector cannot see CUSTOM events; the de-noise layer can —
        # the page demonstrably responded.
        events = [
          mutation(now_ms),
          custom_event(now_ms + 1000, "navigation", {"url" => "https://example.org/", "external" => true}),
          click(now_ms + 1000, 480, 28)
        ]
        save_session("s1", URL, events)

        assert_empty analyze[:pages]
      end

      def test_custom_response_after_the_click_within_the_window_also_rescues
        events = [
          mutation(now_ms),
          click(now_ms + 1000, 480, 28),
          custom_event(now_ms + 1200, "todo_created")
        ]
        save_session("s1", URL, events)

        assert_empty analyze[:pages]
      end

      def test_custom_events_outside_the_response_window_do_not_rescue
        events = [
          mutation(now_ms),
          click(now_ms + 1000, 480, 28),
          custom_event(now_ms + 1501, "todo_created"),
          mutation(now_ms + 5000)
        ]
        save_session("s1", URL, events)

        assert_equal 1, analyze[:pages].fetch(URL)[:dead_count]
      end

      def test_internal_recorder_tags_do_not_rescue_dead_clicks
        # The recorder emits a "__click" annotation for EVERY click — it must
        # never count as a page response, or no click could ever be dead.
        events = [
          mutation(now_ms),
          click(now_ms + 1000, 5, 5),
          click_annotation(now_ms + 1000, "button.inert"),
          custom_event(now_ms + 1005, "__perf", {"metric" => "LCP", "value" => 44})
        ]
        save_session("s1", URL, events)

        assert_equal 1, analyze[:pages].fetch(URL)[:dead_count]
      end

      def test_error_coincident_dead_clicks_are_kept_and_flagged
        # The S1 trigger-error shape: the click fires a JS `error` custom in
        # the same tick and nothing else — genuinely dead, and the most
        # actionable row on the page. It is kept and tagged kind: "error".
        events = [
          mutation(now_ms),
          click(now_ms + 1000, 413, 289),
          custom_event(now_ms + 1000, "error", {"message" => "boom"})
        ]
        save_session("s1", URL, events)

        page = analyze[:pages].fetch(URL)

        assert_equal 1, page[:dead_count]
        incident = page[:incidents].first
        assert_equal "dead_click", incident[:subtype]
        assert_equal "error", incident[:kind]
      end

      def test_plain_dead_clicks_carry_a_nil_kind
        save_session("s1", URL, [mutation(now_ms), click(now_ms + 1000, 5, 5)])

        incident = analyze[:pages].fetch(URL)[:incidents].first

        assert_nil incident[:kind]
      end

      def test_final_click_of_a_navigated_away_segment_is_excluded
        # A slow navigation: the click triggers a page load whose Meta lands
        # 800ms later — outside the pure detector's dead window. The click
        # was the segment's last and another page followed: likely the
        # navigation itself, not a dead click.
        events = [
          meta("https://example.com/", now_ms),
          click(now_ms + 1000, 5, 5),
          meta("https://example.com/slow", now_ms + 1800),
          mutation(now_ms + 1900)
        ]
        save_session("s1", nil, events)

        assert_empty analyze[:pages]
      end

      def test_window_final_click_with_no_navigation_stays_dead
        # The S2 bounce shape: an isolated click on an inert button and the
        # window simply ends. No later segment proves a navigation — this is
        # exactly the designed dead-click signal and must survive.
        events = [
          meta("https://example.com/", now_ms),
          mutation(now_ms + 100),
          click(now_ms + 1500, 716, 400)
        ]
        save_session("s1", nil, events)

        page = analyze[:pages].fetch("https://example.com/")

        assert_equal 1, page[:dead_count]
      end

      def test_earlier_dead_clicks_in_a_navigated_segment_are_kept
        # Only the segment-FINAL click is the likely navigation; earlier
        # unresponded clicks on the page stay dead.
        events = [
          meta("https://example.com/", now_ms),
          click(now_ms + 1000, 5, 5),
          click(now_ms + 3000, 6, 6),
          meta("https://example.com/next", now_ms + 9000),
          mutation(now_ms + 9100)
        ]
        save_session("s1", nil, events)

        page = analyze[:pages].fetch("https://example.com/")

        assert_equal 1, page[:dead_count]
      end

      def test_rage_clusters_are_not_denoised
        # A rage burst right before navigating away is still rage — the
        # exclusion and custom-response rules only apply to dead clicks.
        events = [meta("https://example.com/", now_ms)] +
          rage_burst(now_ms + 100, selector: "button.demo") +
          [custom_event(now_ms + 100, "navigation", {"url" => "x"}),
            meta("https://example.com/next", now_ms + 2000),
            mutation(now_ms + 2100)]
        save_session("s1", nil, events)

        page = analyze[:pages].fetch("https://example.com/")

        assert_equal 1, page[:rage_count]
        assert_equal 0, page[:dead_count]
      end

      def test_ground_truth_bounce_session_keeps_rage_and_isolated_dead_click
        # S2 end-to-end: 5-click rage burst on an inert button, then one
        # isolated click 1.5s later as the window's last event — 1 rage
        # cluster + 1 dead click on /, 1 session affected.
        burst = (0...5).map { |i| click(now_ms + i * 80, 716, 400) }
        events = [meta("https://example.com/", now_ms - 100), mutation(now_ms - 50)] +
          burst + [click(now_ms + 5 * 80 + 1500, 716, 400)]
        save_session("s2", nil, events)

        page = analyze[:pages].fetch("https://example.com/")

        assert_equal 1, page[:rage_count]
        assert_equal 1, page[:dead_count]
        assert_equal 1, page[:sessions_affected]
      end

      # ── bounded accumulation ──

      def test_incidents_are_capped_per_url_but_counts_stay_complete
        cap = FrustrationAnalyzer::MAX_INCIDENTS_PER_URL
        # Dead clicks 600ms apart: never rage (per-pair gap > 500ms), all dead.
        events = (cap + 5).times.map { |i| click(now_ms + i * 600, 5, 5) }
        save_session("s1", URL, events)

        page = analyze[:pages].fetch(URL)

        assert_equal cap + 5, page[:dead_count]
        assert_equal cap, page[:incidents].size
      end

      def test_caps_distinct_urls_and_flags_truncation
        (FrustrationAnalyzer::MAX_URLS + 1).times do |i|
          save_session("s#{i}", "https://example.com/page-#{i}", [click(now_ms, 5, 5)])
        end

        result = analyze

        assert_equal FrustrationAnalyzer::MAX_URLS, result[:pages].size
        assert result[:was_truncated]
      end

      def test_caps_distinct_selectors_per_url_and_flags_truncation
        cap = FrustrationAnalyzer::MAX_SELECTORS_PER_URL
        # One window with (cap + 1) rage bursts, each on its own selector and
        # far enough apart (in time and space) not to merge into one cluster.
        events = []
        (cap + 1).times do |i|
          events.concat(rage_burst(now_ms + i * 2000, x: (i % 50) * 20, y: (i / 50) * 20, selector: "button#b#{i}"))
        end
        save_session("s1", URL, events)

        result = analyze
        page = result[:pages].fetch(URL)

        assert_equal cap + 1, page[:rage_count]
        assert_equal FrustrationAnalyzer::TOP_SELECTORS_LIMIT, page[:top_selectors].size
        assert result[:was_truncated]
      end

      # ── scan cap / truncation ──

      def test_respects_scan_cap
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 1)
        save_session("s1", URL, [click(now_ms, 5, 5)])
        save_session("s2", URL, [click(now_ms, 5, 5)])

        result = analyze

        assert result[:was_truncated]
      end

      def test_explicit_limit_overrides_config
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 5000)
        save_session("s1", URL, [click(now_ms, 5, 5)])
        save_session("s2", URL, [click(now_ms, 5, 5)])

        result = analyze(limit: 1)

        assert_equal 1, result[:pages].fetch(URL)[:dead_count]
        assert result[:was_truncated]
      end

      def test_not_truncated_when_under_cap
        save_session("s1", URL, [click(now_ms, 5, 5)])

        refute analyze[:was_truncated]
      end

      # Truncation must reflect the store scan being capped, even when none of
      # the scanned sessions contributed frustration signals.
      def test_truncated_when_capped_sessions_lack_frustration_data
        save_session("s1", URL, [mutation(now_ms)])
        save_session("s2", URL, [mutation(now_ms)])

        assert analyze(limit: 1)[:was_truncated]
      end

      # ── since/until_time bounds ──

      def test_analyze_honors_date_bounds
        save_session("s1", URL, [click(now_ms, 5, 5)])

        out_of_window = analyze(until_time: Time.now.to_f - 3600)
        in_window = analyze(since: Time.now.to_f - 3600, until_time: Time.now.to_f + 3600)

        assert_empty out_of_window[:pages]
        assert in_window[:pages].key?(URL)
      end
    end
  end
end
