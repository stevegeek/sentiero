# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/collectors/custom_tag_collector"

module Sentiero
  module Analytics
    # Unit-level guarantees for the custom-tag tally shared by
    # StatsAggregator and PageReportAnalyzer. A "segment" is just the array
    # of rrweb event hashes Analyzer#each_page_segment yields.
    class CustomTagCollectorTest < Minitest::Test
      # ── helpers ────────────────────────────────────────────────────────────

      def custom_event(tag, payload: nil)
        data = {"tag" => tag}
        data["payload"] = payload if payload
        {"type" => 5, "data" => data}
      end

      # ── internal_tag? ──────────────────────────────────────────────────────

      def test_double_underscore_prefix_is_internal
        c = CustomTagCollector.new
        assert c.internal_tag?("__click")
        assert c.internal_tag?("__perf")
        assert c.internal_tag?("__")
      end

      def test_error_tag_is_internal
        c = CustomTagCollector.new
        assert c.internal_tag?("error")
      end

      def test_user_tags_are_not_internal
        c = CustomTagCollector.new
        refute c.internal_tag?("purchase")
        refute c.internal_tag?("navigation")
        refute c.internal_tag?("signup")
        # "error" must be an exact match — a tag that starts "error" but
        # differs is NOT internal.
        refute c.internal_tag?("error_custom")
      end

      # ── collect ────────────────────────────────────────────────────────────

      def test_collect_tallies_custom_tags_from_segment
        c = CustomTagCollector.new
        c.collect([custom_event("purchase"), custom_event("signup"), custom_event("purchase")])

        assert_equal({"purchase" => 2, "signup" => 1}, c.tags)
      end

      def test_collect_skips_internal_prefix_tags
        c = CustomTagCollector.new
        c.collect([custom_event("__click"), custom_event("__perf"), custom_event("purchase")])

        assert_equal({"purchase" => 1}, c.tags)
      end

      def test_collect_skips_error_tag
        c = CustomTagCollector.new
        c.collect([custom_event("error"), custom_event("purchase")])

        assert_equal({"purchase" => 1}, c.tags)
      end

      def test_collect_skips_non_custom_event_types
        c = CustomTagCollector.new
        # type 3 is INCREMENTAL, not CUSTOM
        c.collect([{"type" => 3, "data" => {"tag" => "purchase"}}, custom_event("signup")])

        assert_equal({"signup" => 1}, c.tags)
      end

      def test_collect_skips_empty_and_non_string_tags
        c = CustomTagCollector.new
        c.collect([
          {"type" => 5, "data" => {"tag" => ""}},
          {"type" => 5, "data" => {"tag" => nil}},
          {"type" => 5, "data" => {"tag" => 42}},
          custom_event("purchase")
        ])

        assert_equal({"purchase" => 1}, c.tags)
      end

      def test_collect_accumulates_across_multiple_segments
        c = CustomTagCollector.new
        c.collect([custom_event("purchase")])
        c.collect([custom_event("purchase"), custom_event("signup")])

        assert_equal({"purchase" => 2, "signup" => 1}, c.tags)
      end

      # ── tally ──────────────────────────────────────────────────────────────

      def test_tally_counts_tag_and_returns_true
        c = CustomTagCollector.new
        result = c.tally("purchase")

        assert result
        assert_equal({"purchase" => 1}, c.tags)
      end

      def test_tally_returns_false_for_internal_prefix
        c = CustomTagCollector.new
        refute c.tally("__click")
        assert_empty c.tags
      end

      def test_tally_returns_false_for_error_tag
        c = CustomTagCollector.new
        refute c.tally("error")
        assert_empty c.tags
      end

      # ── cap ────────────────────────────────────────────────────────────────

      def test_no_cap_by_default
        c = CustomTagCollector.new
        300.times { |i| c.collect([custom_event("tag_#{i}")]) }

        assert_equal 300, c.tags.size
        refute c.capped
      end

      def test_max_tags_caps_distinct_tags_and_flips_capped
        c = CustomTagCollector.new(max_tags: 2)
        c.collect([custom_event("a"), custom_event("b"), custom_event("c")])

        assert_equal 2, c.tags.size
        assert c.capped
      end

      def test_cap_still_increments_already_seen_tags
        c = CustomTagCollector.new(max_tags: 1)
        c.collect([custom_event("a"), custom_event("a"), custom_event("b")])

        assert_equal({"a" => 2}, c.tags)
        assert c.capped
      end

      def test_tally_returns_false_when_new_tag_would_exceed_cap
        c = CustomTagCollector.new(max_tags: 1)
        c.tally("a")
        result = c.tally("b")

        refute result
        assert c.capped
        assert_equal({"a" => 1}, c.tags)
      end

      # ── top ────────────────────────────────────────────────────────────────

      def test_top_returns_tag_count_hashes_sorted_by_descending_count
        c = CustomTagCollector.new
        c.collect([
          custom_event("checkout"),
          custom_event("checkout"),
          custom_event("checkout"),
          custom_event("signup"),
          custom_event("signup"),
          custom_event("view")
        ])

        assert_equal(
          [{tag: "checkout", count: 3}, {tag: "signup", count: 2}, {tag: "view", count: 1}],
          c.top(10)
        )
      end

      def test_top_limits_to_n
        c = CustomTagCollector.new
        5.times { |i| c.collect([custom_event("tag_#{i}")]) }

        assert_equal 3, c.top(3).size
      end

      def test_top_breaks_count_ties_alphabetically
        c = CustomTagCollector.new
        c.collect([custom_event("b"), custom_event("a")])

        assert_equal [{tag: "a", count: 1}, {tag: "b", count: 1}], c.top(10)
      end

      def test_top_empty_when_no_tags_tallied
        assert_empty CustomTagCollector.new.top(10)
      end
    end
  end
end
