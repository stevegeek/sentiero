# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/page_report_analyzer"

module Sentiero
  module Analytics
    class PageReportAnalyzerTest < Minitest::Test
      TARGET = "https://example.com/signup"

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

      def analyze(url, **opts)
        PageReportAnalyzer.new(@store).analyze(url, **opts)
      end

      # ── event builders (mirror the scroll/heatmap/vitals/form tests) ──

      def meta(href, ts:, width: 1000, height: 800)
        {"type" => 4, "timestamp" => ts, "data" => {"href" => href, "width" => width, "height" => height}}
      end

      def scroll_event(y, ts:)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 3, "id" => 1, "x" => 0, "y" => y}}
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

      def mutation_event(ts:)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 0}}
      end

      def seed(session_id, events, window_id: "w1", url: nil)
        @store.save_events(Sentiero::WindowRef.new(session_id, window_id), events)
        @store.save_metadata(session_id, {"url" => url}) if url
      end

      # ── KEYSTONE: per-URL attribution isolates the target ──

      def test_per_url_attribution_isolates_target
        events = [
          meta("https://example.com/", ts: now_ms),
          click_event(10, 10, ts: now_ms + 1),
          click_tag("a.home", ts: now_ms + 1),
          scroll_event(500, ts: now_ms + 2),
          perf_event("LCP", 1000, "good", ts: now_ms + 3),
          error_event("home boom", ts: now_ms + 4),
          custom_event("home_tag", ts: now_ms + 5),

          meta(TARGET, ts: now_ms + 100),
          click_event(20, 20, ts: now_ms + 101),
          click_tag("button.signup", ts: now_ms + 101),
          scroll_event(900, ts: now_ms + 102),
          perf_event("LCP", 4321, "poor", ts: now_ms + 103),
          error_event("signup boom", ts: now_ms + 104),
          custom_event("signup_tag", ts: now_ms + 105),
          input_event(7, ts: now_ms + 106),

          meta("https://example.com/app", ts: now_ms + 200),
          click_event(30, 30, ts: now_ms + 201),
          click_tag("a.app", ts: now_ms + 201),
          scroll_event(300, ts: now_ms + 202),
          perf_event("LCP", 2000, "good", ts: now_ms + 203),
          error_event("app boom", ts: now_ms + 204),
          custom_event("app_tag", ts: now_ms + 205)
        ]
        seed("s1", events, url: "https://example.com/app")

        result = analyze(TARGET)

        assert_equal TARGET, result[:url]
        assert_equal 1, result[:page_views]
        # heatmap: only the signup click + selector
        assert_equal 1, result[:heatmap][:total_clicks]
        assert_equal [{selector: "button.signup", count: 1}], result[:heatmap][:top_elements]
        # vitals: only the signup LCP (4321)
        assert_equal 4321, result[:vitals][:metrics]["LCP"][:p50]
        assert_equal 1, result[:vitals][:metrics]["LCP"][:samples]
        # errors: only the signup error
        assert_equal 1, result[:errors][:total]
        assert_equal "signup boom", result[:errors][:groups].first[:message]
        # custom events: only signup_tag
        assert_equal [{tag: "signup_tag", count: 1}], result[:custom_events]
        # scroll: only the signup scroll
        refute_nil result[:scroll]
        assert_in_delta 900.0, result[:scroll][:avg_depth_px], 0.01
      end

      def test_time_on_page_mean_and_median
        events = [
          meta(TARGET, ts: now_ms),
          click_event(1, 1, ts: now_ms),
          scroll_event(100, ts: now_ms + 4000)
        ]
        seed("s1", events)

        # A second window with only a single timestamped event on TARGET —
        # contributes NO dwell sample (drop <2-event segments).
        seed("s2", [meta(TARGET, ts: now_ms)], window_id: "w1")

        result = analyze(TARGET)
        ton = result[:time_on_page]

        assert_equal 1, ton[:samples]
        assert_equal 4000, ton[:mean_ms]
        assert_equal 4000, ton[:median_ms]
      end

      def test_time_on_page_counts_revisits_separately
        # A->B->A: two /signup segments => two dwell samples.
        events = [
          meta(TARGET, ts: now_ms),
          scroll_event(1, ts: now_ms + 1000),
          meta("https://example.com/other", ts: now_ms + 2000),
          scroll_event(1, ts: now_ms + 2500),
          meta(TARGET, ts: now_ms + 3000),
          scroll_event(1, ts: now_ms + 6000)
        ]
        seed("s1", events)

        ton = analyze(TARGET)[:time_on_page]

        assert_equal 2, ton[:samples]
      end

      def test_bounce_and_entry_exit
        # s1: only the target segment => bounce + entry + exit.
        seed("s1", [meta(TARGET, ts: now_ms), scroll_event(1, ts: now_ms + 10)])
        # s2: target then another page => entry, not bounce, not exit.
        seed("s2", [
          meta(TARGET, ts: now_ms),
          scroll_event(1, ts: now_ms + 5),
          meta("https://example.com/app", ts: now_ms + 10),
          scroll_event(1, ts: now_ms + 15)
        ])

        ee = analyze(TARGET)[:entry_exit]

        assert_equal 2, ee[:entries]
        assert_equal 1, ee[:exits]
        assert_equal 2, ee[:windows_on_page]
        assert_in_delta 0.5, ee[:bounce_rate], 0.01
      end

      def test_heatmap_top_elements_and_total
        events = [
          meta(TARGET, ts: now_ms),
          click_event(10, 10, ts: now_ms + 1),
          click_tag("button.go", ts: now_ms + 1),
          click_event(11, 11, ts: now_ms + 2),
          click_tag("button.go", ts: now_ms + 2),
          click_event(12, 12, ts: now_ms + 3),
          click_tag("a.help", ts: now_ms + 3)
        ]
        seed("s1", events)

        hm = analyze(TARGET)[:heatmap]

        assert_equal 3, hm[:total_clicks]
        assert_equal({selector: "button.go", count: 2}, hm[:top_elements].first)
        assert_equal({session_id: "s1", window_id: "w1"}, hm[:representative_window])
      end

      # Viewport gate matches /analytics/heatmap: a target segment whose Meta
      # carries no valid width/height contributes ZERO clicks and never becomes
      # the representative window.
      def test_heatmap_segment_without_viewport_contributes_no_clicks
        events = [
          meta(TARGET, ts: now_ms, width: 0, height: 0),
          click_event(10, 10, ts: now_ms + 1),
          click_tag("button.go", ts: now_ms + 2)
        ]
        seed("s1", events)

        hm = analyze(TARGET)[:heatmap]

        assert_equal 0, hm[:total_clicks]
        assert_equal [], hm[:top_elements]
        assert_nil hm[:representative_window]
      end

      def test_scroll_summary_matches_shape
        # Two sessions scrolling the target; deepest per session kept.
        seed("a", [meta(TARGET, ts: now_ms, height: 1000), scroll_event(1000, ts: now_ms + 1)])
        seed("b", [meta(TARGET, ts: now_ms, height: 1000), scroll_event(3000, ts: now_ms + 1)])

        scroll = analyze(TARGET)[:scroll]

        assert_equal 2, scroll[:session_count]
        assert_in_delta 2000.0, scroll[:avg_depth_px], 0.01
        assert scroll.key?(:page_height_px)
        assert scroll.key?(:fold_lines)
        assert scroll.key?(:distribution)
        assert_equal %w[0-25 25-50 50-75 75-100], scroll[:distribution].keys
      end

      def test_forms_started_completed_submits
        events = [
          meta(TARGET, ts: now_ms),
          input_event(7, ts: now_ms + 1),
          input_event(7, ts: now_ms + 2),
          submit_event(ts: now_ms + 3)
        ]
        seed("s1", events)

        forms = analyze(TARGET)[:forms]

        assert_equal 1, forms[:started]
        assert_equal 1, forms[:completed]
        assert_in_delta 1.0, forms[:completion_rate], 0.01
        assert_equal 1, forms[:total_submits]
        assert_equal 1, forms[:fields].size
        assert_equal 7, forms[:fields].first[:field_id]
      end

      # Per-SESSION counting (matches /analytics/forms): a single session that
      # interacts with the form on TWO target-URL segments counts as started: 1,
      # not 2 (the old per-segment counting over-reported).
      def test_forms_started_is_per_session_not_per_segment
        events = [
          meta(TARGET, ts: now_ms),
          input_event(7, ts: now_ms + 1),
          meta("https://example.com/other", ts: now_ms + 100),
          scroll_event(1, ts: now_ms + 101),
          meta(TARGET, ts: now_ms + 200),
          input_event(7, ts: now_ms + 201)
        ]
        seed("s1", events)

        forms = analyze(TARGET)[:forms]

        assert_equal 1, forms[:started]
        # Two abandoned target segments, no submit anywhere.
        assert_equal 0, forms[:completed]
        assert_in_delta 0.0, forms[:completion_rate], 0.01
      end

      def test_forms_completed_per_session
        # Two distinct sessions, each starting + submitting the form.
        seed("s1", [
          meta(TARGET, ts: now_ms),
          input_event(7, ts: now_ms + 1),
          submit_event(ts: now_ms + 2)
        ])
        # s2 submits on TWO target segments — still one completed session.
        seed("s2", [
          meta(TARGET, ts: now_ms),
          input_event(7, ts: now_ms + 1),
          submit_event(ts: now_ms + 2),
          meta("https://example.com/other", ts: now_ms + 100),
          meta(TARGET, ts: now_ms + 200),
          input_event(7, ts: now_ms + 201),
          submit_event(ts: now_ms + 202)
        ])

        forms = analyze(TARGET)[:forms]

        assert_equal 2, forms[:started]
        assert_equal 2, forms[:completed]
        assert_in_delta 1.0, forms[:completion_rate], 0.01
        # total_submits is RAW submit events (1 + 2 = 3), not sessions.
        assert_equal 3, forms[:total_submits]
      end

      def test_vitals_last_sample_per_metric
        events = [
          meta(TARGET, ts: now_ms),
          perf_event("LCP", 1000, "good", ts: now_ms + 1),
          perf_event("LCP", 2000, "needs-improvement", ts: now_ms + 2),
          perf_event("LCP", 3000, "poor", ts: now_ms + 3)
        ]
        seed("s1", events)

        vitals = analyze(TARGET)[:vitals]

        assert_equal 1, vitals[:sample_count]
        lcp = vitals[:metrics]["LCP"]
        assert_equal 1, lcp[:samples]
        # last sample wins => 3000
        assert_equal 3000, lcp[:p50]
      end

      def test_errors_grouped_with_offsets
        events = [
          meta(TARGET, ts: now_ms),
          error_event("TypeError: x is undefined at line 42", ts: now_ms + 100),
          error_event("TypeError: x is undefined at line 99", ts: now_ms + 200)
        ]
        seed("s1", events)

        errors = analyze(TARGET)[:errors]

        assert_equal 2, errors[:total]
        # The two messages normalize to the same group (numbers masked).
        assert_equal 1, errors[:groups].size
        group = errors[:groups].first
        assert_equal 2, group[:count]
        occ = group[:occurrences].first
        assert_equal "s1", occ[:session_id]
        assert_equal "w1", occ[:window_id]
        assert_equal 100, occ[:offset_ms]
      end

      def test_frustration_rage_on_url
        events = [meta(TARGET, ts: now_ms)]
        # 4 rapid clicks at the same spot => one rage cluster.
        4.times do |i|
          events << click_event(50, 50, ts: now_ms + 10 + i * 50)
          events << click_tag("button.broken", ts: now_ms + 10 + i * 50)
        end
        seed("s1", events)

        fr = analyze(TARGET)[:frustration]

        assert fr[:rage_count] >= 1
        assert_equal "button.broken", fr[:top_selectors].first[:selector]
        assert fr.key?(:dead_count)
      end

      def test_custom_events_excludes_internal
        events = [
          meta(TARGET, ts: now_ms),
          custom_event("signup", ts: now_ms + 1),
          perf_event("LCP", 1000, "good", ts: now_ms + 2),
          error_event("boom", ts: now_ms + 3),
          custom_event("promo", ts: now_ms + 4)
        ]
        seed("s1", events)

        tags = analyze(TARGET)[:custom_events].map { |e| e[:tag] }

        assert_includes tags, "promo"
        assert_includes tags, "signup"
        refute_includes tags, "__perf"
        refute_includes tags, "error"
      end

      def test_empty_unknown_url
        seed("s1", [meta(TARGET, ts: now_ms), scroll_event(1, ts: now_ms + 1)])

        result = analyze("https://example.com/nope")

        assert_equal 0, result[:page_views]
        assert_equal 0, result[:sessions]
        assert_equal 0, result[:time_on_page][:samples]
        assert_nil result[:time_on_page][:mean_ms]
        assert_equal 0, result[:entry_exit][:entries]
        assert_equal [], result[:heatmap][:top_elements]
        assert_equal 0, result[:heatmap][:total_clicks]
        assert_nil result[:heatmap][:representative_window]
        assert_nil result[:scroll]
        assert_equal 0, result[:forms][:started]
        assert_equal 0, result[:vitals][:sample_count]
        assert_equal [], result[:errors][:groups]
        assert_equal 0, result[:errors][:total]
        assert_equal 0, result[:frustration][:rage_count]
        assert_equal [], result[:custom_events]
        refute result[:was_truncated]
      end

      def test_truncation_on_scan_cap
        seed("s1", [meta(TARGET, ts: now_ms), scroll_event(1, ts: now_ms + 1)])
        seed("s2", [meta(TARGET, ts: now_ms), scroll_event(1, ts: now_ms + 1)])

        assert analyze(TARGET, limit: 1)[:was_truncated]
      end

      def test_single_scan
        seed("s1", [meta(TARGET, ts: now_ms), scroll_event(1, ts: now_ms + 1)])

        counter = ScanCountingStore.new(@store)
        PageReportAnalyzer.new(counter).analyze(TARGET)

        assert_equal 1, counter.scan_count
      end

      # Wraps a store, counting each_session_events invocations to prove the
      # analyzer makes exactly one scan.
      class ScanCountingStore
        attr_reader :scan_count

        def initialize(inner)
          @inner = inner
          @scan_count = 0
        end

        def each_session_events(**kwargs, &block)
          @scan_count += 1
          @inner.each_session_events(**kwargs, &block)
        end

        def method_missing(name, *args, **kwargs, &block)
          @inner.send(name, *args, **kwargs, &block)
        end

        def respond_to_missing?(name, include_private = false)
          @inner.respond_to?(name, include_private)
        end
      end
    end
  end
end
