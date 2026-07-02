# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/analyzer"

module Sentiero
  module Analytics
    # Analyzer#each_page_segment — the shared Meta-href page-segmentation
    # mechanism every per-page analyzer (heatmap, scroll, vitals,
    # frustration) attributes through.
    class PageSegmentsTest < Minitest::Test
      def setup
        @store = Stores::Memory.new
        Sentiero.configure { |c| c.store = @store }
        @base = Analyzer.new(@store)
      end

      def teardown
        Sentiero.reset_configuration!
      end

      def meta(href, ts:, width: 1280, height: 800)
        data = {"width" => width, "height" => height}
        data["href"] = href if href
        {"type" => 4, "timestamp" => ts, "data" => data}
      end

      def incremental(ts)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 0}}
      end

      def segments_for(events)
        out = []
        @base.send(:each_page_segment, events) do |url, segment, anchor|
          out << [url, segment, anchor]
        end
        out
      end

      def test_empty_events_yield_nothing
        assert_empty segments_for([])
      end

      def test_window_without_meta_hrefs_is_one_nil_url_segment
        events = [incremental(100), incremental(200)]

        segments = segments_for(events)

        assert_equal 1, segments.size
        url, segment, anchor = segments.first
        assert_nil url
        assert_equal events, segment
        assert_equal 100, anchor
      end

      def test_meta_without_href_does_not_open_a_segment
        # A Meta carrying only width/height has no href, so it gives no
        # per-page signal: the whole window stays one nil-url segment.
        events = [meta(nil, ts: 100), incremental(200)]

        segments = segments_for(events)

        assert_equal 1, segments.size
        assert_nil segments.first[0]
        assert_equal events, segments.first[1]
      end

      def test_splits_a_window_on_meta_href_boundaries
        events = [
          meta("https://ex.com/", ts: 100),
          incremental(110),
          meta("https://ex.com/signup", ts: 200),
          incremental(210),
          incremental(220),
          meta("https://ex.com/app", ts: 300),
          incremental(310)
        ]

        segments = segments_for(events)

        assert_equal %w[https://ex.com/ https://ex.com/signup https://ex.com/app],
          segments.map(&:first)
        assert_equal [events[0..1], events[2..4], events[5..6]],
          segments.map { |(_url, segment, _anchor)| segment }
      end

      def test_events_before_the_first_meta_belong_to_the_first_segment
        # DomContentLoaded/Load (types 0/1) precede the first Meta in real
        # recordings; they happened on the first page.
        events = [
          {"type" => 0, "timestamp" => 90, "data" => {}},
          {"type" => 1, "timestamp" => 95, "data" => {}},
          meta("https://ex.com/", ts: 100),
          incremental(110)
        ]

        segments = segments_for(events)

        assert_equal 1, segments.size
        assert_equal events, segments.first[1]
      end

      def test_consecutive_metas_with_the_same_href_extend_the_segment
        # A classic form POST reloads the same URL: one continuous stay on
        # the page, not two page rows.
        events = [
          meta("https://ex.com/app", ts: 100),
          incremental(110),
          meta("https://ex.com/app", ts: 200),
          incremental(210)
        ]

        segments = segments_for(events)

        assert_equal 1, segments.size
        assert_equal "https://ex.com/app", segments.first[0]
        assert_equal events, segments.first[1]
      end

      def test_revisiting_a_url_after_another_page_opens_a_new_segment
        events = [
          meta("https://ex.com/", ts: 100),
          meta("https://ex.com/about", ts: 200),
          meta("https://ex.com/", ts: 300)
        ]

        segments = segments_for(events)

        assert_equal ["https://ex.com/", "https://ex.com/about", "https://ex.com/"],
          segments.map(&:first)
      end

      def test_anchor_is_the_window_first_event_timestamp_for_every_segment
        # Replay deep-links (?t=offset) are relative to the window start, so
        # every segment must share the window anchor, never a local one.
        events = [
          incremental(50),
          meta("https://ex.com/", ts: 100),
          meta("https://ex.com/app", ts: 200),
          incremental(210)
        ]

        segments = segments_for(events)

        assert_equal [50, 50], segments.map { |(_url, _segment, anchor)| anchor }
      end

      def test_blank_or_non_string_hrefs_are_ignored
        events = [
          {"type" => 4, "timestamp" => 100, "data" => {"href" => "", "width" => 1, "height" => 1}},
          {"type" => 4, "timestamp" => 110, "data" => {"href" => 42, "width" => 1, "height" => 1}},
          incremental(120)
        ]

        segments = segments_for(events)

        assert_equal [nil], segments.map(&:first)
      end
    end
  end
end
