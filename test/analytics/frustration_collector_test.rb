# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/collectors/frustration_collector"

module Sentiero
  module Analytics
    # Unit-level guarantees for the per-segment frustration attribution math
    # used by PageReportAnalyzer. A "segment" is the array of rrweb event hashes
    # Analyzer#each_page_segment yields; "incidents" are the raw output of
    # FrustrationAnalyzer.detect_frustration_events (before the refine_incidents
    # de-noise pass — dead_count here is the pre-filter raw count).
    class FrustrationCollectorTest < Minitest::Test
      def click_event(x: 10, y: 10, ts: 1000)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 2, "type" => 2, "x" => x, "y" => y}}
      end

      def click_tag(selector, ts: 1000)
        {"type" => 5, "timestamp" => ts, "data" => {"tag" => "__click", "payload" => {"selector" => selector}}}
      end

      # Mirrors the shape detect_frustration_events returns.
      def rage_incident(event, ts: nil)
        {
          category: "frustration",
          subtype: "rage_click",
          timestamp: ts || event["timestamp"],
          offset: 0,
          count: 3,
          elapsed: nil,
          x: event.dig("data", "x"),
          y: event.dig("data", "y"),
          event: event
        }
      end

      def dead_incident(event, ts: nil)
        {
          category: "frustration",
          subtype: "dead_click",
          timestamp: ts || event["timestamp"],
          offset: 0,
          count: nil,
          elapsed: 500,
          x: event.dig("data", "x"),
          y: event.dig("data", "y"),
          event: event
        }
      end

      def test_empty_incidents_contribute_nothing
        c = FrustrationCollector.new

        attributed = c.collect([], [click_event])

        assert_equal 0, attributed
        assert_equal 0, c.rage_count
        assert_equal 0, c.dead_count
        assert_empty c.selectors
        refute c.capped
      end

      def test_rage_click_increments_rage_count
        event = click_event
        c = FrustrationCollector.new

        c.collect([rage_incident(event)], [event])

        assert_equal 1, c.rage_count
        assert_equal 0, c.dead_count
      end

      def test_dead_click_increments_dead_count
        event = click_event
        c = FrustrationCollector.new

        c.collect([dead_incident(event)], [event])

        assert_equal 0, c.rage_count
        assert_equal 1, c.dead_count
      end

      # Object identity, not value equality: an equal-but-distinct event object
      # is NOT attributed. This is what allows the page report to correctly
      # attribute across segments of the same array (mirrors FrustrationAnalyzer
      # #refine_incidents which uses the same e.equal? trick).
      def test_object_identity_required_not_value_equality
        event = click_event(x: 10, y: 10, ts: 1000)
        clone = click_event(x: 10, y: 10, ts: 1000)
        c = FrustrationCollector.new

        attributed = c.collect([rage_incident(event)], [clone])

        assert_equal 0, attributed
        assert_equal 0, c.rage_count
      end

      def test_incident_belonging_to_other_segment_is_skipped
        event = click_event(x: 10, y: 10)
        other_event = click_event(x: 50, y: 50)
        c = FrustrationCollector.new

        attributed = c.collect([rage_incident(event)], [other_event])

        assert_equal 0, attributed
      end

      def test_rage_click_records_nearest_click_tag_selector
        event = click_event(ts: 1000)
        annotation = click_tag("#button", ts: 1001)
        c = FrustrationCollector.new

        c.collect([rage_incident(event, ts: 1000)], [event, annotation])

        assert_equal({"#button" => 1}, c.selectors)
      end

      # Nearest by absolute timestamp distance — the closer annotation wins.
      def test_nearest_selector_wins_by_distance
        event = click_event(ts: 1000)
        far = click_tag("#far", ts: 1500)
        near = click_tag("#near", ts: 1010)
        c = FrustrationCollector.new

        c.collect([rage_incident(event, ts: 1000)], [event, far, near])

        assert_equal({"#near" => 1}, c.selectors)
      end

      # Dead clicks do not look up selectors — selector tracking is rage-only.
      def test_dead_click_does_not_record_selector
        event = click_event(ts: 1000)
        annotation = click_tag("#button", ts: 1001)
        c = FrustrationCollector.new

        c.collect([dead_incident(event, ts: 1000)], [event, annotation])

        assert_empty c.selectors
      end

      def test_rage_without_click_tag_records_no_selector
        event = click_event
        c = FrustrationCollector.new

        c.collect([rage_incident(event)], [event])

        assert_empty c.selectors
        assert_equal 1, c.rage_count
        refute c.capped
      end

      def test_accumulates_across_multiple_collect_calls
        event_a = click_event(x: 10, y: 10)
        event_b = click_event(x: 20, y: 20)
        c = FrustrationCollector.new

        c.collect([rage_incident(event_a)], [event_a])
        c.collect([dead_incident(event_b)], [event_b])

        assert_equal 1, c.rage_count
        assert_equal 1, c.dead_count
      end

      def test_returns_count_of_attributed_incidents
        event_a = click_event(x: 10, y: 10)
        event_b = click_event(x: 20, y: 20)
        unrelated = click_event(x: 30, y: 30)
        c = FrustrationCollector.new

        attributed = c.collect(
          [rage_incident(event_a), dead_incident(event_b), rage_incident(unrelated)],
          [event_a, event_b]
        )

        assert_equal 2, attributed
      end

      def test_max_selectors_caps_distinct_selectors_and_flips_capped
        c = FrustrationCollector.new(max_selectors: 1)
        event_a = click_event(ts: 1000)
        event_b = click_event(ts: 2000)

        c.collect([rage_incident(event_a, ts: 1000)], [event_a, click_tag("#a", ts: 1000)])
        c.collect([rage_incident(event_b, ts: 2000)], [event_b, click_tag("#b", ts: 2000)])

        assert_equal 1, c.selectors.size
        assert c.capped
      end

      def test_cap_still_increments_already_seen_selector
        c = FrustrationCollector.new(max_selectors: 1)
        event_a = click_event(ts: 1000)
        event_b = click_event(ts: 1001)
        event_c = click_event(ts: 1002)

        c.collect([rage_incident(event_a, ts: 1000)], [event_a, click_tag("#a", ts: 1000)])
        c.collect([rage_incident(event_b, ts: 1001)], [event_b, click_tag("#a", ts: 1001)])
        c.collect([rage_incident(event_c, ts: 1002)], [event_c, click_tag("#b", ts: 1002)])

        assert_equal({"#a" => 2}, c.selectors)
        assert c.capped
      end
    end
  end
end
