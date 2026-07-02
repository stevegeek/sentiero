# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/error_discovery"

module Sentiero
  module Analytics
    class ErrorDiscoveryTest < Minitest::Test
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

      # Saves a window whose events include the given error payloads. The first
      # event anchors the window start so occurrence offsets are deterministic.
      def seed_errors(session_id, window_id, start_ms, errors)
        events = [{"type" => 3, "timestamp" => start_ms}]
        errors.each do |offset_ms, payload|
          events << {
            "type" => 5,
            "timestamp" => start_ms + offset_ms,
            "data" => {"tag" => "error", "payload" => payload}
          }
        end
        @store.save_events(Sentiero::WindowRef.new(session_id, window_id), events)
      end

      def groups_for(sort_by: "count")
        ErrorDiscovery.new(@store).grouped_errors(sort_by: sort_by)[:groups]
      end

      def messages(groups)
        groups.map { |g| g[:message] }
      end

      # ── empty / no errors ──

      def test_empty_store_returns_no_groups
        assert_empty groups_for
      end

      def test_sessions_without_errors_return_no_groups
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          {"type" => 3, "timestamp" => now_ms},
          {"type" => 5, "timestamp" => now_ms + 1, "data" => {"tag" => "click"}}
        ])

        assert_empty groups_for
      end

      # ── basic discovery ──

      def test_discovers_a_single_error
        seed_errors("s1", "w1", now_ms, [
          [500, {"message" => "Boom", "source" => "app.js", "lineno" => 42}]
        ])

        groups = groups_for

        assert_equal 1, groups.size
        group = groups.first
        assert_equal "Boom", group[:message]
        assert_equal "app.js", group[:source]
        assert_equal 42, group[:line]
        assert_equal 1, group[:count]
        assert_equal 1, group[:occurrences].size
      end

      def test_occurrence_records_session_window_and_offset
        seed_errors("s1", "w7", now_ms, [
          [500, {"message" => "Boom", "source" => "app.js", "lineno" => 42}]
        ])

        occ = groups_for.first[:occurrences].first

        assert_equal "s1", occ[:session_id]
        assert_equal "w7", occ[:window_id]
        assert_equal now_ms + 500, occ[:timestamp]
        assert_equal 500, occ[:offset_ms]
      end

      # ── grouping / dedup ──

      def test_identical_messages_group_together
        seed_errors("s1", "w1", now_ms, [[100, {"message" => "Boom"}]])
        seed_errors("s2", "w1", now_ms, [[100, {"message" => "Boom"}]])

        groups = groups_for

        assert_equal 1, groups.size
        assert_equal 2, groups.first[:count]
        assert_equal 2, groups.first[:occurrences].size
      end

      def test_different_messages_form_separate_groups
        seed_errors("s1", "w1", now_ms, [
          [100, {"message" => "Boom"}],
          [200, {"message" => "Kaboom"}]
        ])

        groups = groups_for

        assert_equal 2, groups.size
        assert_includes messages(groups), "Boom"
        assert_includes messages(groups), "Kaboom"
      end

      def test_messages_differing_only_by_numbers_normalize_together
        seed_errors("s1", "w1", now_ms, [
          [100, {"message" => "Timeout after 5000ms"}],
          [200, {"message" => "Timeout after 9000ms"}]
        ])

        groups = groups_for

        assert_equal 1, groups.size
        assert_equal 2, groups.first[:count]
      end

      def test_grouping_uses_first_line_ignoring_stack_trace
        seed_errors("s1", "w1", now_ms, [
          [100, {"message" => "Boom\n  at foo (app.js:1)\n  at bar (app.js:2)"}],
          [200, {"message" => "Boom\n  at baz (other.js:9)"}]
        ])

        groups = groups_for

        assert_equal 1, groups.size
        assert_equal 2, groups.first[:count]
      end

      # ── stable id ──

      def test_group_has_a_stable_id
        seed_errors("s1", "w1", now_ms, [[100, {"message" => "Boom"}]])

        id = groups_for.first[:id]

        refute_nil id
        assert_match(/\A[0-9a-f]+\z/, id) # URL-safe hex digest
      end

      def test_same_input_yields_same_id_across_requests
        seed_errors("s1", "w1", now_ms, [[100, {"message" => "Boom"}]])

        assert_equal groups_for.first[:id], groups_for.first[:id]
      end

      def test_different_messages_have_different_ids
        seed_errors("s1", "w1", now_ms, [
          [100, {"message" => "Boom"}],
          [200, {"message" => "Kaboom"}]
        ])

        ids = groups_for.map { |g| g[:id] }

        assert_equal 2, ids.size
        assert_equal ids.size, ids.uniq.size
      end

      def test_id_derives_from_dedup_key_not_full_message
        # Two messages that share the normalized dedup key (differ only by a
        # number) collapse into one group and therefore one id.
        seed_errors("s1", "w1", now_ms, [
          [100, {"message" => "Timeout after 5000ms"}],
          [200, {"message" => "Timeout after 9000ms"}]
        ])

        groups = groups_for

        assert_equal 1, groups.size
        refute_nil groups.first[:id]
      end

      # ── sorting ──

      def test_default_sort_is_by_count_descending
        seed_errors("s1", "w1", now_ms, [[100, {"message" => "rare"}]])
        seed_errors("s2", "w1", now_ms, [
          [100, {"message" => "common"}],
          [200, {"message" => "common"}],
          [300, {"message" => "common"}]
        ])

        groups = groups_for

        assert_equal ["common", "rare"], messages(groups)
      end

      def test_sort_by_recency_orders_by_last_seen
        seed_errors("s1", "w1", now_ms, [
          [100, {"message" => "old"}],
          [200, {"message" => "old"}]
        ])
        seed_errors("s2", "w1", now_ms + 10_000, [[100, {"message" => "new"}]])

        groups = groups_for(sort_by: "recency")

        assert_equal ["new", "old"], messages(groups)
      end

      # ── malformed payloads ──

      def test_missing_message_falls_back_to_unknown
        seed_errors("s1", "w1", now_ms, [[100, {"source" => "app.js"}]])

        group = groups_for.first

        assert_equal "Unknown error", group[:message]
      end

      def test_non_string_message_is_coerced
        seed_errors("s1", "w1", now_ms, [[100, {"message" => 12_345}]])

        group = groups_for.first

        assert_equal "12345", group[:message]
      end

      def test_non_hash_payload_is_ignored
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          {"type" => 3, "timestamp" => now_ms},
          {"type" => 5, "timestamp" => now_ms + 1, "data" => {"tag" => "error", "payload" => "oops"}}
        ])

        group = groups_for.first

        assert_equal "Unknown error", group[:message]
      end

      def test_missing_source_and_line_are_nil
        seed_errors("s1", "w1", now_ms, [[100, {"message" => "Boom"}]])

        group = groups_for.first

        assert_nil group[:source]
        assert_nil group[:line]
      end

      # ── occurrence cap ──

      def test_occurrences_are_capped_per_group
        cap = ErrorDiscovery::MAX_OCCURRENCES_PER_GROUP
        firings = Array.new(cap + 10) { |i| [i + 1, {"message" => "Boom"}] }
        seed_errors("s1", "w1", now_ms, firings)

        group = groups_for.first

        assert_equal cap + 10, group[:count]
        assert_equal cap, group[:occurrences].size
      end

      # ── scan cap ──

      def test_respects_scan_cap
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 1)
        seed_errors("s1", "w1", now_ms, [[100, {"message" => "a"}]])
        seed_errors("s2", "w1", now_ms + 1000, [[100, {"message" => "b"}]])

        groups = groups_for

        total = groups.sum { |g| g[:count] }
        assert_equal 1, total
      end

      # ── B2: per-group browser/device/page facets ──

      CHROME_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
      SAFARI_IPHONE_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

      def test_groups_carry_browser_device_and_page_facets
        seed_errors("s1", "w1", now_ms, [
          [100, {"message" => "Boom"}],
          [200, {"message" => "Boom"}]
        ])
        @store.save_metadata("s1", {"userAgent" => CHROME_UA, "url" => "https://ex.com/checkout"})
        seed_errors("s2", "w1", now_ms, [[100, {"message" => "Boom"}]])
        @store.save_metadata("s2", {"userAgent" => SAFARI_IPHONE_UA, "url" => "https://ex.com/cart"})

        group = groups_for.first

        # Tallies are per OCCURRENCE (rides the same scan; no extra store reads).
        assert_equal 2, group[:browsers]["Chrome"]
        assert_equal 1, group[:browsers]["Safari"]
        assert_equal 2, group[:devices]["Desktop"]
        assert_equal 1, group[:devices]["Mobile"]
        assert_equal 2, group[:pages]["https://ex.com/checkout"]
        assert_equal 1, group[:pages]["https://ex.com/cart"]
      end

      def test_facets_empty_without_session_metadata
        seed_errors("s1", "w1", now_ms, [[100, {"message" => "Boom"}]])

        group = groups_for.first

        assert_empty group[:browsers]
        assert_empty group[:devices]
        assert_empty group[:pages]
      end

      def test_facet_distinct_values_are_capped_per_group
        cap = ErrorDiscovery::MAX_FACET_VALUES
        (cap + 5).times do |i|
          seed_errors("s#{i}", "w1", now_ms + i, [[100, {"message" => "Boom"}]])
          @store.save_metadata("s#{i}", {"url" => "https://ex.com/p#{i}"})
        end

        group = groups_for.first

        # Distinct keys are bounded (memory cap), but counting never stops.
        assert_equal cap, group[:pages].size
        assert_equal cap + 5, group[:count]
      end

      # ── since/until_time bounds ──

      def test_grouped_errors_honors_date_bounds
        seed_errors("s1", "w1", now_ms, [[100, {"message" => "Boom"}]])

        out_of_window = ErrorDiscovery.new(@store)
          .grouped_errors(until_time: Time.now.to_f - 3600)[:groups]
        in_window = ErrorDiscovery.new(@store)
          .grouped_errors(since: Time.now.to_f - 3600, until_time: Time.now.to_f + 3600)[:groups]

        assert_empty out_of_window
        assert_equal ["Boom"], messages(in_window)
      end
    end
  end
end
