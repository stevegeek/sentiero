# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/engagement_analyzer"

module Sentiero
  module Analytics
    class EngagementAnalyzerTest < Minitest::Test
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

      # ── event builders (mirror frustration_analyzer_test.rb) ──

      def click(ts, x, y)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 2, "type" => 2, "x" => x, "y" => y}}
      end

      def mutation(ts)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 0, "adds" => [], "removes" => [], "attributes" => [], "texts" => []}}
      end

      def scroll(ts, y)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 3, "y" => y}}
      end

      def input(ts, id)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 5, "id" => id, "text" => "x"}}
      end

      # NOTE: href first, ts second — matches frustration_analyzer_test.rb#meta.
      def meta(href, ts)
        {"type" => 4, "timestamp" => ts, "data" => {"href" => href, "width" => 1280, "height" => 800}}
      end

      def custom_event(ts, tag, payload = {})
        {"type" => 5, "timestamp" => ts, "data" => {"tag" => tag, "payload" => payload}}
      end

      def navigation(ts, url)
        custom_event(ts, "navigation", {"url" => url})
      end

      def now_ms
        @now_ms ||= (Time.now.to_f * 1000).round
      end

      def save_session(session_id, url, events, window_id: "w1")
        @store.save_events(Sentiero::WindowRef.new(session_id, window_id), events)
        @store.save_metadata(session_id, {"url" => url}) if url
      end

      def analyze(**opts)
        EngagementAnalyzer.new(@store).analyze(**opts)
      end

      def first_session(result)
        result[:sessions].first
      end

      # ══════════════════════════════════════════════════════════════════

      def test_weights_sum_to_one
        assert_in_delta 1.0, EngagementAnalyzer::WEIGHTS.values.sum, 1e-9
      end

      def test_clean_session_scores_zero
        # Multiple distinct pages keep quick_bounce false; long enough that
        # idle_ratio stays 0 (no gap over the threshold).
        events = [
          meta(URL, now_ms),
          mutation(now_ms + 100),
          scroll(now_ms + 200, 100),
          scroll(now_ms + 300, 200),
          meta("https://example.com/done", now_ms + 6000)
        ]
        save_session("clean", URL, events)

        result = analyze
        row = first_session(result)

        assert_equal 0, row[:score]
        signals = row[:signals]
        assert_equal 0, signals[:rage_clicks]
        assert_equal 0, signals[:dead_clicks]
        assert_equal 0, signals[:nav_churn]
        assert_in_delta 0.0, signals[:idle_ratio], 1e-9
        assert_equal 0, signals[:thrashing_scroll]
        refute signals[:quick_bounce]
        assert_equal 0, signals[:form_refills]
        refute signals[:error_abandonment]
        assert_equal 1, result[:distribution]["0-20"]
      end

      def test_rage_clicks_raise_score
        # A 3-click rage burst within 500ms at the same spot, plus a mutation
        # right after so the burst isn't ALSO dead, and enough duration so
        # quick_bounce stays false.
        events = [
          meta(URL, now_ms),
          click(now_ms + 100, 10, 10),
          click(now_ms + 200, 10, 10),
          click(now_ms + 300, 10, 10),
          mutation(now_ms + 350),
          mutation(now_ms + 9000)
        ]
        save_session("rage", URL, events)

        row = first_session(analyze)

        assert_equal 1, row[:signals][:rage_clicks]
        assert_equal (0.20 * (1 / 3.0) * 100).round, row[:score]
      end

      def test_dead_click_counted
        # An isolated click with no response within the dead window; later
        # activity keeps duration past the quick-bounce threshold.
        events = [
          meta(URL, now_ms),
          mutation(now_ms + 100),
          click(now_ms + 1000, 5, 5),
          mutation(now_ms + 9000)
        ]
        save_session("dead", URL, events)

        row = first_session(analyze)

        assert row[:signals][:dead_clicks] >= 1
        assert row[:score] > 0
      end

      def test_quick_bounce
        bounce = [meta(URL, now_ms), mutation(now_ms + 1000)]
        save_session("bounce", URL, bounce)

        stay = [meta(URL, now_ms), mutation(now_ms + 6000)]
        save_session("stay", URL, stay)

        rows = analyze[:sessions].each_with_object({}) { |r, h| h[r[:session_id]] = r }

        assert rows["bounce"][:signals][:quick_bounce]
        refute rows["stay"][:signals][:quick_bounce]
      end

      def test_idle_ratio
        # One big gap (>10s) over a 20s session => idle_ratio ~ 1.0.
        idle = [meta(URL, now_ms), mutation(now_ms + 20_000)]
        save_session("idle", URL, idle)

        # Dense events, no gap over the threshold => 0.0.
        dense = [
          meta(URL, now_ms),
          mutation(now_ms + 1000),
          mutation(now_ms + 2000),
          mutation(now_ms + 3000)
        ]
        save_session("dense", URL, dense)

        rows = analyze[:sessions].each_with_object({}) { |r, h| h[r[:session_id]] = r }

        assert_in_delta 1.0, rows["idle"][:signals][:idle_ratio], 1e-9
        assert_in_delta 0.0, rows["dense"][:signals][:idle_ratio], 1e-9
      end

      def test_thrashing_scroll
        # y: 0 -> 400 -> 50 -> 500 -> 60, each <1s apart, deltas > 100, signs
        # flip (+400, -350, +450, -440): 3 reversals.
        events = [
          meta(URL, now_ms),
          scroll(now_ms + 100, 0),
          scroll(now_ms + 300, 400),
          scroll(now_ms + 500, 50),
          scroll(now_ms + 700, 500),
          scroll(now_ms + 900, 60)
        ]
        save_session("thrash", URL, events)

        assert first_session(analyze)[:signals][:thrashing_scroll] >= 2
      end

      def test_nav_churn_counts_revisits
        # /a -> /b -> /a : one revisit (the second /a).
        churn1 = [
          meta("https://example.com/a", now_ms),
          meta("https://example.com/b", now_ms + 1000),
          meta("https://example.com/a", now_ms + 2000)
        ]
        save_session("churn1", nil, churn1)

        # /a -> /b -> /a -> /b : two revisits.
        churn2 = [
          meta("https://example.com/a", now_ms),
          meta("https://example.com/b", now_ms + 1000),
          meta("https://example.com/a", now_ms + 2000),
          meta("https://example.com/b", now_ms + 3000)
        ]
        save_session("churn2", nil, churn2)

        # /a four times: 3 revisits, saturates the sub-score.
        churn4 = [
          meta("https://example.com/a", now_ms),
          meta("https://example.com/a", now_ms + 1000),
          meta("https://example.com/a", now_ms + 2000),
          meta("https://example.com/a", now_ms + 3000)
        ]
        save_session("churn4", nil, churn4)

        rows = analyze[:sessions].each_with_object({}) { |r, h| h[r[:session_id]] = r }

        assert_equal 1, rows["churn1"][:signals][:nav_churn]
        assert rows["churn2"][:signals][:nav_churn] >= 2
        assert_equal 3, rows["churn4"][:signals][:nav_churn]
      end

      def test_form_refills_counts_repeat_inputs
        refilled = [
          meta(URL, now_ms),
          input(now_ms + 100, 42),
          input(now_ms + 200, 42),
          input(now_ms + 300, 42)
        ]
        save_session("refill", URL, refilled)

        once = [meta(URL, now_ms), input(now_ms + 100, 7)]
        save_session("once", URL, once)

        rows = analyze[:sessions].each_with_object({}) { |r, h| h[r[:session_id]] = r }

        assert_equal 2, rows["refill"][:signals][:form_refills]
        assert_equal 0, rows["once"][:signals][:form_refills]
      end

      def test_error_abandonment
        # Error custom within 8s of the last event => abandonment true.
        abandoned = [
          meta(URL, now_ms),
          mutation(now_ms + 1000),
          custom_event(now_ms + 5000, "error", {"message" => "boom"})
        ]
        save_session("abandoned", URL, abandoned)

        # Error early, then 30s more activity => false.
        recovered = [
          meta(URL, now_ms),
          custom_event(now_ms + 1000, "error", {"message" => "boom"}),
          mutation(now_ms + 31_000)
        ]
        save_session("recovered", URL, recovered)

        rows = analyze[:sessions].each_with_object({}) { |r, h| h[r[:session_id]] = r }

        assert rows["abandoned"][:signals][:error_abandonment]
        refute rows["recovered"][:signals][:error_abandonment]
      end

      def test_multi_window_session_aggregates_once
        # Window 1: a rage burst. Window 2: an isolated dead click. Both
        # belong to the SAME session => one row carrying both signals.
        w1 = [
          meta(URL, now_ms),
          click(now_ms + 100, 10, 10),
          click(now_ms + 200, 10, 10),
          click(now_ms + 300, 10, 10),
          mutation(now_ms + 350)
        ]
        w2 = [
          meta(URL, now_ms + 1000),
          mutation(now_ms + 1100),
          click(now_ms + 2000, 5, 5),
          mutation(now_ms + 9000)
        ]
        save_session("multi", URL, w1, window_id: "wA")
        save_session("multi", URL, w2, window_id: "wB")

        result = analyze
        rows = result[:sessions].select { |r| r[:session_id] == "multi" }

        assert_equal 1, rows.size
        signals = rows.first[:signals]
        assert_equal 1, signals[:rage_clicks]
        assert signals[:dead_clicks] >= 1
      end

      def test_distribution_sums_to_scanned_and_rows_sorted
        # A clean session (score 0) and a rage session (score > 0).
        save_session("clean", URL, [meta(URL, now_ms), mutation(now_ms + 6000)])
        rage = [
          meta(URL, now_ms),
          click(now_ms + 100, 10, 10),
          click(now_ms + 200, 10, 10),
          click(now_ms + 300, 10, 10),
          mutation(now_ms + 350),
          mutation(now_ms + 9000)
        ]
        save_session("rage", URL, rage)

        result = analyze

        assert_equal result[:scanned], result[:distribution].values.sum
        scores = result[:sessions].map { |r| r[:score] }
        assert_equal scores.sort.reverse, scores

        # First window seen for a session is reported.
        assert result[:sessions].all? { |r| r[:window_id] == "w1" }
      end

      def test_bin_boundaries
        assert_equal "0-20", EngagementAnalyzer.bin_for(0)
        assert_equal "0-20", EngagementAnalyzer.bin_for(19)
        assert_equal "20-40", EngagementAnalyzer.bin_for(20)
        assert_equal "80-100", EngagementAnalyzer.bin_for(100)
      end

      def test_was_truncated_on_scan_cap
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 1)
        save_session("s1", URL, [meta(URL, now_ms), mutation(now_ms + 100)])
        save_session("s2", URL, [meta(URL, now_ms), mutation(now_ms + 100)])

        result = analyze

        assert result[:was_truncated]
        assert_equal 1, result[:scanned]
      end

      def test_row_cap_does_not_set_truncated
        cap = EngagementAnalyzer::MAX_SESSIONS
        total = cap + 5
        total.times do |i|
          save_session("s#{i}", URL, [meta(URL, now_ms), mutation(now_ms + 6000)])
        end

        result = analyze

        assert_equal cap, result[:sessions].size
        assert_equal total, result[:distribution].values.sum
        assert_equal total, result[:scanned]
        refute result[:was_truncated]
      end
    end
  end
end
