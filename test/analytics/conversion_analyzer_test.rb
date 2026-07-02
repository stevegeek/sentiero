# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/conversion_analyzer"

module Sentiero
  module Analytics
    class ConversionAnalyzerTest < Minitest::Test
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

      # Seeds a session window whose FIRST event is a Meta (type 4) carrying the
      # entry href, followed by one custom event (type 5) per tag. Also persists
      # immutable entry_url/entry_referrer metadata (the recorder's authoritative
      # acquisition data). save_events MUST precede save_metadata: the Memory
      # store's save_metadata is a no-op until the session row exists.
      def seed_session(id, entry_url:, referrer: "", tags: [], window_id: "w1", at: now_ms)
        events = [{"type" => 4, "timestamp" => at, "data" => {"href" => entry_url}}]
        tags.each_with_index do |tag, i|
          events << {"type" => 5, "timestamp" => at + (i + 1) * 100, "data" => {"tag" => tag, "payload" => {}}}
        end
        @store.save_events(Sentiero::WindowRef.new(id, window_id), events)
        @store.save_metadata(id, {"entry_url" => entry_url, "entry_referrer" => referrer})
      end

      def analyze(tag = nil, **opts)
        ConversionAnalyzer.new(@store).analyze(tag, **opts)
      end

      # ── tag vocabulary ──

      def test_vocabulary_excludes_internal_tags
        seed_session("s1", entry_url: "https://x/a", tags: %w[signup __perf error checkout])

        result = analyze(nil)

        assert_equal %w[checkout signup], result[:tags]
        assert_nil result[:selected_tag]
        assert_empty result[:entry_pages]
        assert_empty result[:referrers]
        assert_equal [], result[:utm][:source]
      end

      def test_no_tag_selected_yields_empty_facets
        seed_session("s1", entry_url: "https://x/a", tags: %w[checkout])

        result = analyze(nil)

        assert_nil result[:selected_tag]
        assert_empty result[:entry_pages]
        assert_empty result[:referrers]
        assert_equal [], result[:utm][:source]
        assert_equal [], result[:utm][:medium]
        assert_equal [], result[:utm][:campaign]
      end

      # ── entry-page conversion ──

      def test_entry_page_rate_counts_per_session
        seed_session("s1", entry_url: "https://x/pricing", tags: %w[checkout])
        seed_session("s2", entry_url: "https://x/pricing")
        seed_session("s3", entry_url: "https://x/pricing")

        rows = analyze("checkout")[:entry_pages]

        assert_equal 1, rows.size
        row = rows.first
        assert_equal "https://x/pricing", row[:key]
        assert_equal 3, row[:sessions]
        assert_equal 1, row[:conversions]
        assert_in_delta 33.3, row[:conversion_rate], 0.01
      end

      def test_entry_page_key_strips_query_and_fragment
        seed_session("s1", entry_url: "https://x/p?a=1#h")
        seed_session("s2", entry_url: "https://x/p?b=2")

        rows = analyze("checkout")[:entry_pages]

        assert_equal 1, rows.size
        assert_equal "https://x/p", rows.first[:key]
        assert_equal 2, rows.first[:sessions]
      end

      def test_conversion_counted_once_per_session
        seed_session("s1", entry_url: "https://x/p", tags: %w[checkout checkout checkout])

        row = analyze("checkout")[:entry_pages].first

        assert_equal 1, row[:sessions]
        assert_equal 1, row[:conversions]
      end

      def test_conversion_tag_in_a_later_window_still_counts
        seed_session("s1", entry_url: "https://x/p", window_id: "w1", at: now_ms)
        # checkout in a second window of the same session
        @store.save_events(
          Sentiero::WindowRef.new("s1", "w2"),
          [
            {"type" => 4, "timestamp" => now_ms + 10_000, "data" => {"href" => "https://x/checkout"}},
            {"type" => 5, "timestamp" => now_ms + 10_500, "data" => {"tag" => "checkout"}}
          ]
        )

        row = analyze("checkout")[:entry_pages].first

        assert_equal 1, row[:conversions]
        assert_equal "w2", row[:converting_example][:window_id]
      end

      # ── referrers ──

      def test_referrer_host_buckets_and_drops_same_origin
        seed_session("s1", entry_url: "https://x/a", referrer: "https://google.com/q")
        seed_session("s2", entry_url: "https://x/a", referrer: "https://x/prev")
        seed_session("s3", entry_url: "https://x/a", referrer: "")

        rows = analyze("checkout")[:referrers]
        keys = rows.map { |r| r[:key] }

        assert_includes keys, "google.com"
        assert_includes keys, ConversionAnalyzer::DIRECT
        refute_includes keys, "x"
        # google.com (1) + (direct/none) (1) — same-origin x/prev dropped
        assert_equal 2, rows.size
      end

      # ── UTM ──

      def test_utm_parsed_from_entry_url
        seed_session("s1", entry_url: "https://x/a?utm_source=Google&utm_medium=cpc&utm_campaign=spring")

        utm = analyze("checkout")[:utm]

        assert_equal "Google", utm[:source].first[:key]
        assert_equal "cpc", utm[:medium].first[:key]
        assert_equal "spring", utm[:campaign].first[:key]
      end

      def test_utm_param_name_is_case_insensitive
        seed_session("s1", entry_url: "https://x/a?UTM_Source=Bing")

        utm = analyze("checkout")[:utm]

        assert_equal "Bing", utm[:source].first[:key]
      end

      def test_missing_utm_param_produces_no_row
        seed_session("s1", entry_url: "https://x/a")

        assert_equal [], analyze("checkout")[:utm][:source]
      end

      # ── conversion rate / flags ──

      def test_conversion_rate_nil_guard_and_low_volume_flag
        seed_session("s1", entry_url: "https://low/p", tags: %w[checkout])
        6.times { |i| seed_session("h#{i}", entry_url: "https://high/p", tags: %w[checkout]) }

        rows = analyze("checkout")[:entry_pages]
        low = rows.find { |r| r[:key] == "https://low/p" }
        high = rows.find { |r| r[:key] == "https://high/p" }

        assert_in_delta 100.0, low[:conversion_rate], 0.01
        assert low[:low_volume]
        assert_in_delta 100.0, high[:conversion_rate], 0.01
        refute high[:low_volume]
      end

      def test_examples_carry_replay_coordinates
        seed_session("conv", entry_url: "https://x/p", tags: %w[checkout])
        seed_session("noconv", entry_url: "https://x/p")

        row = analyze("checkout")[:entry_pages].first

        assert_equal 100, row[:converting_example][:offset_ms]
        assert_equal "conv", row[:converting_example][:session_id]
        assert_equal "w1", row[:converting_example][:window_id]
        assert_equal 0, row[:non_converting_example][:offset_ms]
        assert_equal "noconv", row[:non_converting_example][:session_id]
      end

      def test_rows_sorted_by_sessions_desc_and_capped
        n = ConversionAnalyzer::TOP_ROWS + 5
        n.times do |i|
          # give page i exactly (i+1) sessions so order is deterministic
          (i + 1).times { |j| seed_session("s#{i}_#{j}", entry_url: "https://x/p#{i}") }
        end

        rows = analyze("checkout")[:entry_pages]

        assert_equal ConversionAnalyzer::TOP_ROWS, rows.size
        sessions = rows.map { |r| r[:sessions] }
        assert_equal sessions.sort.reverse, sessions
      end

      # ── caps / truncation ──

      def test_respects_scan_cap_and_limit_override
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 1)
        seed_session("s1", entry_url: "https://x/a", tags: %w[checkout])
        seed_session("s2", entry_url: "https://x/b", tags: %w[checkout])

        assert analyze("checkout")[:was_truncated]

        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 5000)
        assert analyze("checkout", limit: 1)[:was_truncated]
      end

      def test_dimension_key_cap_flags_truncation
        n = ConversionAnalyzer::MAX_DIMENSION_KEYS + 5
        n.times { |i| seed_session("s#{i}", entry_url: "https://x/p#{i}") }

        result = analyze("checkout")

        assert result[:was_truncated]
      end

      # ── date bounds ──

      def test_honors_date_bounds
        seed_session("s1", entry_url: "https://x/a", tags: %w[checkout])

        out_of_window = analyze("checkout", until_time: Time.now.to_f - 3600)
        in_window = analyze("checkout", since: Time.now.to_f - 3600, until_time: Time.now.to_f + 3600)

        assert_empty out_of_window[:entry_pages]
        assert_equal 1, in_window[:entry_pages].size
      end

      # ── malformed input ──

      def test_ignores_malformed_metadata_and_events
        # Window with no Meta, no entry_url metadata, no url ⇒ no entry_pages row.
        @store.save_events(
          Sentiero::WindowRef.new("s1", "w1"),
          [
            {"type" => 3, "timestamp" => now_ms},
            {"type" => 5, "timestamp" => now_ms + 1, "data" => {"tag" => 42}},
            {"type" => 5, "timestamp" => now_ms + 2, "data" => "nope"},
            {"type" => 5, "timestamp" => now_ms + 3}
          ]
        )

        result = analyze("checkout")

        assert_empty result[:entry_pages]
        assert_empty result[:referrers]
      end
    end
  end
end
