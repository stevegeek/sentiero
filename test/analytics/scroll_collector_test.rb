# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/collectors/scroll_collector"

module Sentiero
  module Analytics
    # Unit-level guarantees for the per-segment scroll-depth math shared by
    # ScrollDepthAnalyzer and PageReportAnalyzer. Callers feed segments per
    # window via #observe, then #flush_window commits each URL's deepest
    # segment as one depth sample.
    class ScrollCollectorTest < Minitest::Test
      URL = "https://example.com/home"

      def meta(height:, width: 1000)
        {"type" => 4, "timestamp" => 0, "data" => {"width" => width, "height" => height}}
      end

      def scroll(y, ts: 1)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 3, "y" => y}}
      end

      def test_summarizes_a_single_window_depth
        c = ScrollCollector.new
        c.observe(URL, [meta(height: 600), scroll(800)])
        c.flush_window

        summary = c.summarize(URL)
        assert_equal 1, summary[:session_count]
        assert_in_delta 800.0, summary[:avg_depth_px]
        assert_equal 1400, summary[:page_height_px] # 800 + 600 viewport
        assert_in_delta 100.0, summary[:avg_depth_pct]
        assert_equal({"0-25" => 0, "25-50" => 0, "50-75" => 0, "75-100" => 1}, summary[:distribution])
      end

      def test_deepest_segment_wins_within_a_window
        c = ScrollCollector.new
        c.observe(URL, [meta(height: 600), scroll(300)])
        c.observe(URL, [meta(height: 600), scroll(900)])
        c.flush_window

        summary = c.summarize(URL)
        assert_equal 1, summary[:session_count]
        assert_in_delta 900.0, summary[:avg_depth_px]
      end

      def test_each_window_contributes_one_sample
        c = ScrollCollector.new
        c.observe(URL, [meta(height: 600), scroll(400)])
        c.flush_window
        c.observe(URL, [meta(height: 600), scroll(800)])
        c.flush_window

        assert_equal 2, c.summarize(URL)[:session_count]
      end

      def test_segment_without_scroll_contributes_nothing
        c = ScrollCollector.new
        c.observe(URL, [meta(height: 600)])
        c.flush_window

        assert_nil c.summarize(URL)
      end

      def test_unscanned_url_summarizes_to_nil
        assert_nil ScrollCollector.new.summarize(URL)
      end

      # viewport-less depth: no percentage derivable, distribution falls back
      # to pixels relative to the deepest sample.
      def test_depth_without_viewport_height_has_no_percentage
        c = ScrollCollector.new
        c.observe(URL, [scroll(500)])
        c.flush_window

        summary = c.summarize(URL)
        assert_in_delta 500.0, summary[:avg_depth_px]
        assert_nil summary[:avg_depth_pct]
        assert_nil summary[:page_height_px]
        assert_equal({"0-25" => 0, "25-50" => 0, "50-75" => 0, "75-100" => 1}, summary[:distribution])
      end

      def test_inner_element_scrolls_do_not_inflate_page_depth
        inner_scroll = {"type" => 3, "timestamp" => 1, "data" => {"source" => 3, "id" => 5, "y" => 5000}}
        c = ScrollCollector.new
        c.observe(URL, [meta(height: 600), scroll(300), inner_scroll])
        c.flush_window

        summary = c.summarize(URL)
        assert_in_delta 300.0, summary[:avg_depth_px], 0.001, "inner scroll (id > 1) must be ignored"
      end

      def test_pages_returns_every_scanned_url
        c = ScrollCollector.new
        c.observe("/a", [meta(height: 600), scroll(300)])
        c.observe("/b", [meta(height: 600), scroll(600)])
        c.flush_window

        assert_equal %w[/a /b], c.pages.keys.sort
      end

      def test_max_urls_caps_distinct_urls_and_flips_capped
        c = ScrollCollector.new(max_urls: 1)
        c.observe("/a", [meta(height: 600), scroll(300)])
        c.observe("/b", [meta(height: 600), scroll(600)])
        c.flush_window

        assert_equal ["/a"], c.pages.keys
        assert c.capped
      end
    end
  end
end
