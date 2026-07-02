# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/collectors/vitals_collector"

module Sentiero
  module Analytics
    # Unit-level guarantees for the per-segment web-vitals math shared by
    # WebVitalsAnalyzer and PageReportAnalyzer. A "segment" is the array of
    # rrweb event hashes Analyzer#each_page_segment yields; session_id, window_id,
    # and anchor are supplied per collect call so worst-sample attribution can
    # include session/window identity and replay offset.
    class VitalsCollectorTest < Minitest::Test
      NOW = 1_000_000

      def perf(metric, value, rating: "good", ts: NOW + 100)
        {
          "type" => 5,
          "timestamp" => ts,
          "data" => {"tag" => "__perf", "payload" => {"metric" => metric, "value" => value, "rating" => rating}}
        }
      end

      def collect(collector, segment, session_id: "s1", window_id: "w1", anchor: NOW)
        collector.collect(segment, session_id: session_id, window_id: window_id, anchor: anchor)
      end

      # ── empty / no vitals ──

      def test_empty_segment_produces_empty_summary
        c = VitalsCollector.new
        collect(c, [])

        summary = c.summarize
        assert_equal 0, summary[:sample_count]
        assert_empty summary[:metrics]
      end

      def test_segment_with_no_perf_events_produces_empty_summary
        c = VitalsCollector.new
        segment = [
          {"type" => 3, "timestamp" => NOW, "data" => {"source" => 2}},
          {"type" => 5, "timestamp" => NOW + 1, "data" => {"tag" => "__click", "payload" => {}}}
        ]
        collect(c, segment)

        assert_empty c.summarize[:metrics]
      end

      # ── parsing ──

      def test_parses_valid_perf_event
        c = VitalsCollector.new
        collect(c, [perf("LCP", 2400.0, rating: "good")])

        metrics = c.summarize[:metrics]
        assert metrics.key?("LCP")
        assert_equal 1, metrics["LCP"][:samples]
        assert_in_delta 2400.0, metrics["LCP"][:p50], 0.01
      end

      def test_ignores_non_custom_event_type
        c = VitalsCollector.new
        # type 3 (incremental), not type 5 (custom)
        collect(c, [{"type" => 3, "timestamp" => NOW, "data" => {"tag" => "__perf", "payload" => {"metric" => "LCP", "value" => 1000}}}])

        assert_empty c.summarize[:metrics]
      end

      def test_ignores_wrong_tag
        c = VitalsCollector.new
        collect(c, [{"type" => 5, "timestamp" => NOW, "data" => {"tag" => "perf", "payload" => {"metric" => "LCP", "value" => 1000}}}])

        assert_empty c.summarize[:metrics]
      end

      def test_ignores_non_string_metric
        c = VitalsCollector.new
        collect(c, [{"type" => 5, "timestamp" => NOW, "data" => {"tag" => "__perf", "payload" => {"metric" => 7, "value" => 1000}}}])

        assert_empty c.summarize[:metrics]
      end

      def test_ignores_empty_metric_string
        c = VitalsCollector.new
        collect(c, [{"type" => 5, "timestamp" => NOW, "data" => {"tag" => "__perf", "payload" => {"metric" => "", "value" => 1000}}}])

        assert_empty c.summarize[:metrics]
      end

      def test_ignores_non_numeric_value
        c = VitalsCollector.new
        collect(c, [{"type" => 5, "timestamp" => NOW, "data" => {"tag" => "__perf", "payload" => {"metric" => "LCP", "value" => "fast"}}}])

        assert_empty c.summarize[:metrics]
      end

      def test_ignores_missing_payload
        c = VitalsCollector.new
        collect(c, [{"type" => 5, "timestamp" => NOW, "data" => {"tag" => "__perf"}}])

        assert_empty c.summarize[:metrics]
      end

      # ── last-sample-per-metric-per-segment collapse (A5) ──

      # web-vitals re-reports the same metric while a page is alive (each new
      # candidate supersedes the previous). Only the LAST report in a segment
      # is that page view's authoritative value.
      def test_multiple_same_metric_in_segment_collapses_to_last
        c = VitalsCollector.new
        collect(c, [
          perf("LCP", 1000, ts: NOW + 10),
          perf("LCP", 2400, ts: NOW + 20),
          perf("LCP", 800, ts: NOW + 30)
        ])

        lcp = c.summarize[:metrics]["LCP"]
        assert_equal 1, lcp[:samples]
        assert_in_delta 800.0, lcp[:p50], 0.01
      end

      def test_different_metrics_tracked_independently_within_segment
        c = VitalsCollector.new
        collect(c, [perf("LCP", 2400), perf("CLS", 0.05), perf("INP", 350)])

        summary = c.summarize
        assert_equal 3, summary[:sample_count]
        assert_equal %w[CLS INP LCP], summary[:metrics].keys.sort
      end

      def test_accumulates_samples_across_multiple_collect_calls
        c = VitalsCollector.new
        collect(c, [perf("LCP", 1000)], session_id: "s1")
        collect(c, [perf("LCP", 2000)], session_id: "s2")
        collect(c, [perf("LCP", 3000)], session_id: "s3")

        assert_equal 3, c.summarize[:metrics]["LCP"][:samples]
      end

      # ── rating histogram ──

      def test_tallies_ratings_verbatim
        c = VitalsCollector.new
        collect(c, [perf("LCP", 1000, rating: "good")], session_id: "s1")
        collect(c, [perf("LCP", 5000, rating: "poor")], session_id: "s2")
        collect(c, [perf("LCP", 3000, rating: "needs-improvement")], session_id: "s3")

        assert_equal({"good" => 1, "poor" => 1, "needs-improvement" => 1},
          c.summarize[:metrics]["LCP"][:ratings])
      end

      def test_nil_rating_not_tallied_but_sample_still_counted
        c = VitalsCollector.new
        collect(c, [perf("LCP", 1000, rating: nil)])

        lcp = c.summarize[:metrics]["LCP"]
        assert_equal 1, lcp[:samples]
        assert_empty lcp[:ratings]
      end

      def test_empty_string_rating_not_tallied
        c = VitalsCollector.new
        collect(c, [perf("LCP", 1000, rating: "")])

        assert_empty c.summarize[:metrics]["LCP"][:ratings]
      end

      # ── worst-sample tracking ──

      def test_worst_is_the_highest_value_sample
        c = VitalsCollector.new
        collect(c, [perf("LCP", 1200)], session_id: "fast", window_id: "wf")
        collect(c, [perf("LCP", 8200)], session_id: "slow", window_id: "ws")
        collect(c, [perf("LCP", 3000)], session_id: "mid", window_id: "wm")

        worst = c.summarize[:metrics]["LCP"][:worst]
        assert_equal "slow", worst[:session_id]
        assert_equal "ws", worst[:window_id]
        assert_in_delta 8200.0, worst[:value], 0.01
      end

      def test_worst_updates_when_higher_value_arrives
        c = VitalsCollector.new
        collect(c, [perf("LCP", 5000)], session_id: "first", window_id: "w1")
        collect(c, [perf("LCP", 9000)], session_id: "second", window_id: "w2")

        assert_equal "second", c.summarize[:metrics]["LCP"][:worst][:session_id]
      end

      def test_worst_not_updated_by_lower_value
        c = VitalsCollector.new
        collect(c, [perf("LCP", 5000)], session_id: "first", window_id: "w1")
        collect(c, [perf("LCP", 4999)], session_id: "second", window_id: "w2")

        assert_equal "first", c.summarize[:metrics]["LCP"][:worst][:session_id]
      end

      def test_worst_carries_offset_ms_relative_to_anchor
        c = VitalsCollector.new
        # anchor at NOW, perf event at NOW + 500 → offset_ms 500
        collect(c, [perf("INP", 900, ts: NOW + 500)], anchor: NOW)

        assert_equal 500, c.summarize[:metrics]["INP"][:worst][:offset_ms]
      end

      def test_worst_offset_ms_is_zero_when_anchor_nil
        c = VitalsCollector.new
        collect(c, [perf("LCP", 1000, ts: NOW)], anchor: nil)

        assert_equal 0, c.summarize[:metrics]["LCP"][:worst][:offset_ms]
      end

      def test_worst_offset_ms_clamped_to_zero_when_event_before_anchor
        c = VitalsCollector.new
        # event timestamp before anchor → clamped to 0
        collect(c, [perf("LCP", 1000, ts: NOW - 100)], anchor: NOW)

        assert_equal 0, c.summarize[:metrics]["LCP"][:worst][:offset_ms]
      end

      # Worst reflects the final collapsed value, not an earlier candidate that
      # was superseded within the segment. An early LCP of 9000 dropped to 1000
      # at the end of the segment: the recorded sample is 1000.
      def test_worst_reflects_final_collapsed_value_not_early_candidate
        c = VitalsCollector.new
        collect(c, [
          perf("LCP", 9000, ts: NOW + 10),
          perf("LCP", 1000, ts: NOW + 20)
        ], session_id: "s1", window_id: "w1")

        worst = c.summarize[:metrics]["LCP"][:worst]
        assert_in_delta 1000.0, worst[:value], 0.01
      end

      # ── sample cap ──

      def test_unbounded_never_caps
        c = VitalsCollector.new
        100.times { |i| collect(c, [perf("LCP", i * 10)], session_id: "s#{i}") }

        assert_equal 100, c.summarize[:metrics]["LCP"][:samples]
        refute c.capped
      end

      def test_max_samples_caps_and_flips_capped
        c = VitalsCollector.new(max_samples: 2)
        collect(c, [perf("LCP", 1000)], session_id: "s1")
        collect(c, [perf("LCP", 2000)], session_id: "s2")
        collect(c, [perf("LCP", 3000)], session_id: "s3") # rejected

        assert_equal 2, c.summarize[:metrics]["LCP"][:samples]
        assert c.capped
      end

      def test_cap_is_enforced_per_metric_independently
        c = VitalsCollector.new(max_samples: 1)
        # LCP fills its bucket on the first call; CLS on the second is still accepted.
        collect(c, [perf("LCP", 1000), perf("CLS", 0.1)], session_id: "s1")
        collect(c, [perf("LCP", 2000), perf("CLS", 0.2)], session_id: "s2")

        assert_equal 1, c.summarize[:metrics]["LCP"][:samples]
        assert_equal 1, c.summarize[:metrics]["CLS"][:samples]
        assert c.capped
      end

      # ── percentiles ──

      def test_percentiles_nearest_rank
        c = VitalsCollector.new
        [1000, 2000, 3000, 4000, 5000].each_with_index do |value, i|
          collect(c, [perf("LCP", value)], session_id: "s#{i}")
        end

        lcp = c.summarize[:metrics]["LCP"]
        assert_in_delta 3000.0, lcp[:p50], 0.01
        assert_in_delta 4000.0, lcp[:p75], 0.01
        assert_in_delta 5000.0, lcp[:p90], 0.01
      end

      def test_single_sample_all_percentiles_equal_the_value
        c = VitalsCollector.new
        collect(c, [perf("CLS", 0.31)])

        cls = c.summarize[:metrics]["CLS"]
        assert_in_delta 0.31, cls[:p50], 0.001
        assert_in_delta 0.31, cls[:p75], 0.001
        assert_in_delta 0.31, cls[:p90], 0.001
      end

      # ── summarize output shape ──

      def test_sample_count_is_sum_across_all_metrics
        c = VitalsCollector.new
        collect(c, [perf("LCP", 1000), perf("CLS", 0.1), perf("INP", 300)])
        collect(c, [perf("LCP", 2000)], session_id: "s2")

        assert_equal 4, c.summarize[:sample_count]
      end
    end
  end
end
