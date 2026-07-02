# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/collectors/error_collector"

module Sentiero
  module Analytics
    # Unit-level guarantees for the per-segment error grouping math shared by
    # ErrorDiscovery and PageReportAnalyzer. A "segment" is just the array of
    # rrweb event hashes Analyzer#each_page_segment yields; session_id/window_id/
    # anchor come from the caller (each_session_events + each_page_segment).
    class ErrorCollectorTest < Minitest::Test
      def error_event(message: "Boom", ts: 100)
        {
          "type" => 5,
          "timestamp" => ts,
          "data" => {"tag" => "error", "payload" => {"message" => message}}
        }
      end

      def non_error_event(ts: 50)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 2}}
      end

      def anchor_ts
        0
      end

      def collect_one(collector, segment, session_id: "s1", window_id: "w1", anchor: anchor_ts)
        collector.collect(segment, session_id: session_id, window_id: window_id, anchor: anchor)
      end

      # ── empty / non-error events ───────────────────────────────────────────

      def test_empty_segment_leaves_groups_empty
        c = ErrorCollector.new
        collect_one(c, [])

        assert_empty c.groups
        refute c.capped
      end

      def test_non_error_events_are_ignored
        c = ErrorCollector.new
        collect_one(c, [non_error_event])

        assert_empty c.groups
      end

      def test_custom_event_with_wrong_tag_is_ignored
        c = ErrorCollector.new
        event = {"type" => 5, "timestamp" => 1, "data" => {"tag" => "click", "payload" => {"message" => "x"}}}
        collect_one(c, [event])

        assert_empty c.groups
      end

      # ── basic accumulation ────────────────────────────────────────────────

      def test_single_error_creates_one_group_with_count_and_occurrence
        c = ErrorCollector.new
        collect_one(c, [error_event(message: "Boom", ts: 500)], session_id: "s1", window_id: "w1", anchor: 0)

        assert_equal 1, c.groups.size
        group = c.groups.values.first
        assert_equal "Boom", group[:message]
        assert_equal 1, group[:count]
        assert_equal 1, group[:occurrences].size
      end

      def test_occurrence_records_session_id_window_id_and_offset_ms
        c = ErrorCollector.new
        collect_one(c, [error_event(message: "Boom", ts: 500)], session_id: "ses42", window_id: "win7", anchor: 0)

        occ = c.groups.values.first[:occurrences].first
        assert_equal "ses42", occ[:session_id]
        assert_equal "win7", occ[:window_id]
        assert_equal 500, occ[:offset_ms]
      end

      def test_offset_ms_is_event_timestamp_minus_anchor
        c = ErrorCollector.new
        collect_one(c, [error_event(ts: 1000)], anchor: 400)

        occ = c.groups.values.first[:occurrences].first
        assert_equal 600, occ[:offset_ms]
      end

      def test_offset_ms_is_clamped_to_zero_when_event_precedes_anchor
        c = ErrorCollector.new
        collect_one(c, [error_event(ts: 100)], anchor: 200)

        occ = c.groups.values.first[:occurrences].first
        assert_equal 0, occ[:offset_ms]
      end

      def test_offset_ms_is_zero_when_anchor_is_nil
        c = ErrorCollector.new
        collect_one(c, [error_event(ts: 500)], anchor: nil)

        occ = c.groups.values.first[:occurrences].first
        assert_equal 0, occ[:offset_ms]
      end

      # ── grouping / dedup ──────────────────────────────────────────────────

      def test_identical_messages_increment_count_in_one_group
        c = ErrorCollector.new
        collect_one(c, [error_event(message: "Boom"), error_event(message: "Boom")])

        assert_equal 1, c.groups.size
        assert_equal 2, c.groups.values.first[:count]
      end

      def test_different_messages_form_separate_groups
        c = ErrorCollector.new
        collect_one(c, [error_event(message: "Boom"), error_event(message: "Kaboom")])

        assert_equal 2, c.groups.size
        assert_equal %w[Boom Kaboom], c.groups.values.map { |g| g[:message] }.sort
      end

      def test_messages_differing_only_by_digits_normalize_to_one_group
        c = ErrorCollector.new
        collect_one(c, [
          error_event(message: "Timeout after 5000ms"),
          error_event(message: "Timeout after 9000ms")
        ])

        assert_equal 1, c.groups.size
        assert_equal 2, c.groups.values.first[:count]
      end

      def test_grouping_uses_first_line_ignoring_stack_trace
        c = ErrorCollector.new
        collect_one(c, [
          error_event(message: "Boom\n  at foo (app.js:1)"),
          error_event(message: "Boom\n  at bar (other.js:9)")
        ])

        assert_equal 1, c.groups.size
        assert_equal 2, c.groups.values.first[:count]
      end

      def test_accumulates_across_multiple_collect_calls
        c = ErrorCollector.new
        collect_one(c, [error_event(message: "Boom")])
        collect_one(c, [error_event(message: "Boom"), error_event(message: "Kaboom")])

        assert_equal 2, c.groups.size
        boom_group = c.groups.find { |_k, g| g[:message] == "Boom" }&.last
        assert_equal 2, boom_group[:count]
      end

      # ── missing / malformed payloads ──────────────────────────────────────

      def test_missing_message_falls_back_to_unknown_error
        c = ErrorCollector.new
        event = {"type" => 5, "timestamp" => 1, "data" => {"tag" => "error", "payload" => {}}}
        collect_one(c, [event])

        assert_equal "Unknown error", c.groups.values.first[:message]
      end

      def test_blank_message_falls_back_to_unknown_error
        c = ErrorCollector.new
        event = {"type" => 5, "timestamp" => 1, "data" => {"tag" => "error", "payload" => {"message" => "  "}}}
        collect_one(c, [event])

        assert_equal "Unknown error", c.groups.values.first[:message]
      end

      def test_non_hash_payload_falls_back_to_unknown_error
        c = ErrorCollector.new
        event = {"type" => 5, "timestamp" => 1, "data" => {"tag" => "error", "payload" => "oops"}}
        collect_one(c, [event])

        assert_equal "Unknown error", c.groups.values.first[:message]
      end

      def test_non_string_message_is_coerced_to_string
        c = ErrorCollector.new
        event = {"type" => 5, "timestamp" => 1, "data" => {"tag" => "error", "payload" => {"message" => 12_345}}}
        collect_one(c, [event])

        assert_equal "12345", c.groups.values.first[:message]
      end

      # ── max_groups cap ────────────────────────────────────────────────────

      def test_unbounded_max_groups_never_caps
        c = ErrorCollector.new
        # Letter-only suffixes so group_key normalization doesn't collapse them.
        %w[alpha beta gamma delta epsilon zeta eta theta iota kappa].each do |msg|
          collect_one(c, [error_event(message: msg)])
        end

        assert_equal 10, c.groups.size
        refute c.capped
      end

      def test_max_groups_cap_drops_new_groups_and_flips_capped
        c = ErrorCollector.new(max_groups: 2)
        collect_one(c, [
          error_event(message: "Alpha"),
          error_event(message: "Beta"),
          error_event(message: "Gamma")  # exceeds cap
        ])

        assert_equal 2, c.groups.size
        assert c.capped
      end

      def test_capped_group_still_increments_known_keys
        c = ErrorCollector.new(max_groups: 1)
        collect_one(c, [
          error_event(message: "Alpha"),
          error_event(message: "Alpha"),  # same key → should increment
          error_event(message: "Beta")    # new key → dropped
        ])

        assert_equal 1, c.groups.size
        assert_equal 2, c.groups.values.first[:count]
        assert c.capped
      end

      # ── max_occurrences cap ───────────────────────────────────────────────

      def test_unbounded_max_occurrences_never_drops
        c = ErrorCollector.new
        50.times { collect_one(c, [error_event(message: "Boom")]) }

        assert_equal 50, c.groups.values.first[:occurrences].size
      end

      def test_max_occurrences_stops_appending_after_cap
        c = ErrorCollector.new(max_occurrences: 3)
        5.times { collect_one(c, [error_event(message: "Boom")]) }

        group = c.groups.values.first
        assert_equal 5, group[:count]
        assert_equal 3, group[:occurrences].size
      end

      # ── summarize ─────────────────────────────────────────────────────────

      def test_summarize_returns_groups_sorted_by_count_descending
        c = ErrorCollector.new
        collect_one(c, [error_event(message: "rare")])
        collect_one(c, [error_event(message: "common"), error_event(message: "common"), error_event(message: "common")])

        summary = c.summarize
        assert_equal %w[common rare], summary[:groups].map { |g| g[:message] }
      end

      def test_summarize_returns_total_count_across_all_groups
        c = ErrorCollector.new
        collect_one(c, [error_event(message: "Alpha"), error_event(message: "Beta"), error_event(message: "Alpha")])

        assert_equal 3, c.summarize[:total]
      end

      def test_summarize_group_shape_contains_message_count_occurrences
        c = ErrorCollector.new
        collect_one(c, [error_event(message: "Boom", ts: 500)], session_id: "s1", window_id: "w1", anchor: 0)

        group = c.summarize[:groups].first
        assert_equal "Boom", group[:message]
        assert_equal 1, group[:count]
        assert_equal 1, group[:occurrences].size
        assert_equal({session_id: "s1", window_id: "w1", offset_ms: 500}, group[:occurrences].first)
      end

      def test_summarize_on_empty_collector_returns_empty_groups_and_zero_total
        c = ErrorCollector.new
        summary = c.summarize

        assert_empty summary[:groups]
        assert_equal 0, summary[:total]
      end

      # ── class-level utility methods ───────────────────────────────────────
      # error_event?, group_key, extract_message are class-level so callers
      # (e.g. ErrorDiscovery) can reuse the shared definitions without creating
      # an accumulator instance.

      def test_error_event_returns_true_for_custom_type_with_error_tag
        event = {"type" => 5, "data" => {"tag" => "error"}}
        assert ErrorCollector.error_event?(event)
      end

      def test_error_event_returns_false_for_wrong_type
        event = {"type" => 3, "data" => {"tag" => "error"}}
        refute ErrorCollector.error_event?(event)
      end

      def test_error_event_returns_false_for_wrong_tag
        event = {"type" => 5, "data" => {"tag" => "click"}}
        refute ErrorCollector.error_event?(event)
      end

      def test_error_event_returns_false_for_non_hash_data
        event = {"type" => 5, "data" => "bad"}
        refute ErrorCollector.error_event?(event)
      end

      def test_group_key_masks_digits_and_takes_first_line
        key = ErrorCollector.group_key("Timeout after 5000ms\n  at foo (app.js:12)")
        assert_equal "Timeout after #ms", key
      end

      def test_group_key_is_capped_at_max_key_length
        long_message = "E" * 300
        key = ErrorCollector.group_key(long_message)
        assert_equal ErrorCollector::MAX_KEY_LENGTH, key.length
      end

      def test_extract_message_returns_message_string
        event = {"type" => 5, "data" => {"tag" => "error", "payload" => {"message" => "Boom"}}}
        assert_equal "Boom", ErrorCollector.extract_message(event)
      end

      def test_extract_message_falls_back_to_unknown_error_when_missing
        event = {"type" => 5, "data" => {"tag" => "error", "payload" => {}}}
        assert_equal "Unknown error", ErrorCollector.extract_message(event)
      end

      def test_extract_message_coerces_non_string_to_string
        event = {"type" => 5, "data" => {"tag" => "error", "payload" => {"message" => 42}}}
        assert_equal "42", ErrorCollector.extract_message(event)
      end
    end
  end
end
