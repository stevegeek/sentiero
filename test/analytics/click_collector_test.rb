# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/collectors/click_collector"

module Sentiero
  module Analytics
    # Unit-level guarantees for the per-segment click math shared by
    # HeatmapAnalyzer and PageReportAnalyzer. A "segment" is just the array of
    # rrweb event hashes Analyzer#each_page_segment yields.
    class ClickCollectorTest < Minitest::Test
      def meta(width:, height:)
        {"type" => 4, "timestamp" => 0, "data" => {"width" => width, "height" => height}}
      end

      def click(x, y, ts: 1)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 2, "type" => 2, "x" => x, "y" => y}}
      end

      def scroll(y, ts: 1)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 3, "id" => 1, "y" => y}}
      end

      def click_tag(selector, ts: 1)
        {"type" => 5, "timestamp" => ts, "data" => {"tag" => "__click", "payload" => {"selector" => selector}}}
      end

      def test_counts_native_clicks_and_returns_added
        c = ClickCollector.new
        added = c.collect([meta(width: 1000, height: 1000), click(100, 100), click(200, 200)])

        assert_equal 2, added
        assert_equal 2, c.total
      end

      def test_segment_without_viewport_collects_nothing_and_returns_nil
        c = ClickCollector.new
        added = c.collect([click(100, 100), click(200, 200)])

        assert_nil added
        assert_equal 0, c.total
        assert_empty c.buckets
      end

      def test_accumulates_across_multiple_segments
        c = ClickCollector.new
        c.collect([meta(width: 1000, height: 1000), click(10, 10)])
        c.collect([meta(width: 1000, height: 1000), click(20, 20), click(30, 30)])

        assert_equal 3, c.total
      end

      def test_tallies_click_tag_selectors
        c = ClickCollector.new
        c.collect([meta(width: 1000, height: 1000), click_tag("#buy"), click_tag("#buy"), click_tag(".nav")])

        assert_equal({"#buy" => 2, ".nav" => 1}, c.selectors)
      end

      # The page-relative bucketing is the math page report previously skipped:
      # a click's document Y is its viewport Y plus the running scroll offset,
      # normalized against deepest-scroll + viewport height.
      def test_buckets_click_by_page_relative_coordinate
        c = ClickCollector.new
        # scroll to y=500, then click at viewport (200, 100) => page_y 600,
        # page_height = 500 + 1000 = 1500. col floor(200/1000*20)=4,
        # row floor(600/1500*20)=8.
        c.collect([meta(width: 1000, height: 1000), scroll(500), click(200, 100)])

        assert_equal({[4, 8] => 1}, c.buckets)
      end

      def test_unbounded_selectors_never_caps
        c = ClickCollector.new
        300.times { |i| c.collect([meta(width: 1000, height: 1000), click_tag("#sel#{i}")]) }

        assert_equal 300, c.selectors.size
        refute c.capped
      end

      def test_max_selectors_caps_distinct_selectors_and_flips_capped
        c = ClickCollector.new(max_selectors: 2)
        c.collect([meta(width: 1000, height: 1000), click_tag("#a"), click_tag("#b"), click_tag("#c")])

        assert_equal 2, c.selectors.size
        assert c.capped
      end

      def test_cap_still_increments_already_seen_selectors
        c = ClickCollector.new(max_selectors: 1)
        c.collect([meta(width: 1000, height: 1000), click_tag("#a"), click_tag("#a"), click_tag("#b")])

        assert_equal({"#a" => 2}, c.selectors)
        assert c.capped
      end
    end
  end
end
