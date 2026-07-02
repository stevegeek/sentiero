# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/segmenter"

module Sentiero
  module Analytics
    class SegmenterTest < Minitest::Test
      CHROME_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
      SAFARI_IPHONE_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
      FIREFOX_UA = "Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0"

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

      def seed_session(id, metadata: {}, duration_ms: 1_000)
        @store.save_events(Sentiero::WindowRef.new(id, "w1"), [
          {"type" => 3, "timestamp" => now_ms},
          {"type" => 3, "timestamp" => now_ms + duration_ms}
        ])
        @store.save_metadata(id, metadata) unless metadata.empty?
      end

      def ids(result)
        result[:sessions].map { |s| s[:session_id] }
      end

      # ── no filters ──

      def test_no_filters_returns_all_sessions
        seed_session("a", metadata: {"userAgent" => CHROME_UA})
        seed_session("b", metadata: {"userAgent" => FIREFOX_UA})

        result = Segmenter.new(@store).matching

        assert_equal 2, result[:sessions].size
        assert_includes ids(result), "a"
        assert_includes ids(result), "b"
      end

      def test_empty_store_returns_no_sessions
        result = Segmenter.new(@store).matching

        assert_empty result[:sessions]
        refute result[:was_truncated]
      end

      # ── browser ──

      def test_browser_filter
        seed_session("chrome", metadata: {"userAgent" => CHROME_UA})
        seed_session("firefox", metadata: {"userAgent" => FIREFOX_UA})

        result = Segmenter.new(@store, browser: "Chrome").matching

        assert_equal ["chrome"], ids(result)
      end

      def test_blank_browser_does_not_filter
        seed_session("chrome", metadata: {"userAgent" => CHROME_UA})

        result = Segmenter.new(@store, browser: "").matching

        assert_equal ["chrome"], ids(result)
      end

      def test_session_without_user_agent_excluded_by_browser_filter
        seed_session("noua")

        result = Segmenter.new(@store, browser: "Chrome").matching

        assert_empty result[:sessions]
      end

      # ── device ──

      def test_device_filter
        seed_session("desktop", metadata: {"userAgent" => CHROME_UA})
        seed_session("mobile", metadata: {"userAgent" => SAFARI_IPHONE_UA})

        result = Segmenter.new(@store, device: "Mobile").matching

        assert_equal ["mobile"], ids(result)
      end

      # ── url pattern (substring, case-insensitive) ──

      def test_url_pattern_substring_match
        seed_session("checkout", metadata: {"url" => "https://shop.example.com/checkout"})
        seed_session("home", metadata: {"url" => "https://shop.example.com/home"})

        result = Segmenter.new(@store, url_pattern: "checkout").matching

        assert_equal ["checkout"], ids(result)
      end

      def test_url_pattern_is_case_insensitive
        seed_session("checkout", metadata: {"url" => "https://shop.example.com/Checkout"})

        result = Segmenter.new(@store, url_pattern: "checkout").matching

        assert_equal ["checkout"], ids(result)
      end

      def test_url_pattern_glob_match
        seed_session("a", metadata: {"url" => "https://example.com/users/42/edit"})
        seed_session("b", metadata: {"url" => "https://example.com/posts/42/edit"})

        result = Segmenter.new(@store, url_pattern: "*/users/*/edit").matching

        assert_equal ["a"], ids(result)
      end

      def test_session_without_url_excluded_by_url_filter
        seed_session("nourl")

        result = Segmenter.new(@store, url_pattern: "checkout").matching

        assert_empty result[:sessions]
      end

      # ── custom metadata key/value ──

      def test_metadata_exact_match
        seed_session("paid", metadata: {"plan" => "pro"})
        seed_session("free", metadata: {"plan" => "free"})

        result = Segmenter.new(@store, metadata_key: "plan", metadata_value: "pro").matching

        assert_equal ["paid"], ids(result)
      end

      def test_metadata_contains_match
        seed_session("a", metadata: {"tags" => "alpha,beta,gamma"})
        seed_session("b", metadata: {"tags" => "delta"})

        result = Segmenter.new(@store, metadata_key: "tags", metadata_value: "beta", metadata_match: "contains").matching

        assert_equal ["a"], ids(result)
      end

      def test_metadata_key_present_without_value_matches_any_value
        seed_session("a", metadata: {"coupon" => "SAVE10"})
        seed_session("b", metadata: {"plan" => "free"})

        result = Segmenter.new(@store, metadata_key: "coupon").matching

        assert_equal ["a"], ids(result)
      end

      def test_metadata_missing_key_excluded
        seed_session("a", metadata: {"plan" => "pro"})

        result = Segmenter.new(@store, metadata_key: "absent", metadata_value: "x").matching

        assert_empty result[:sessions]
      end

      # ── has_errors ──

      def test_has_errors_filter
        seed_session("err", metadata: {"has_errors" => true})
        seed_session("ok")

        result = Segmenter.new(@store, has_errors: true).matching

        assert_equal ["err"], ids(result)
      end

      def test_has_errors_false_value_excluded
        seed_session("flagged_false", metadata: {"has_errors" => false})

        result = Segmenter.new(@store, has_errors: true).matching

        assert_empty result[:sessions]
      end

      # ── duration range ──

      def test_min_duration_filter
        seed_session("short", duration_ms: 5_000)
        seed_session("long", duration_ms: 60_000)

        result = Segmenter.new(@store, min_duration_ms: 30_000).matching

        assert_equal ["long"], ids(result)
      end

      def test_max_duration_filter
        seed_session("short", duration_ms: 5_000)
        seed_session("long", duration_ms: 60_000)

        result = Segmenter.new(@store, max_duration_ms: 30_000).matching

        assert_equal ["short"], ids(result)
      end

      def test_duration_range_filter
        seed_session("tiny", duration_ms: 1_000)
        seed_session("mid", duration_ms: 45_000)
        seed_session("huge", duration_ms: 600_000)

        result = Segmenter.new(@store, min_duration_ms: 30_000, max_duration_ms: 120_000).matching

        assert_equal ["mid"], ids(result)
      end

      # ── combined AND logic ──

      def test_filters_combine_with_and_logic
        seed_session("match", metadata: {"userAgent" => SAFARI_IPHONE_UA, "url" => "https://x.com/cart"}, duration_ms: 45_000)
        seed_session("wrong_device", metadata: {"userAgent" => CHROME_UA, "url" => "https://x.com/cart"}, duration_ms: 45_000)
        seed_session("wrong_url", metadata: {"userAgent" => SAFARI_IPHONE_UA, "url" => "https://x.com/home"}, duration_ms: 45_000)
        seed_session("wrong_duration", metadata: {"userAgent" => SAFARI_IPHONE_UA, "url" => "https://x.com/cart"}, duration_ms: 1_000)

        result = Segmenter.new(@store,
          device: "Mobile",
          url_pattern: "cart",
          min_duration_ms: 30_000).matching

        assert_equal ["match"], ids(result)
      end

      # ── pagination ──

      def test_pagination_limit_and_offset
        10.times { |i| seed_session("s#{i}", metadata: {"userAgent" => CHROME_UA}) }

        page1 = Segmenter.new(@store, browser: "Chrome").matching(limit: 4, offset: 0)
        page2 = Segmenter.new(@store, browser: "Chrome").matching(limit: 4, offset: 4)

        assert_equal 4, page1[:sessions].size
        assert_equal 4, page2[:sessions].size
        assert_empty(ids(page1) & ids(page2))
        assert result(page1, :has_next)
      end

      def test_has_next_false_on_last_page
        3.times { |i| seed_session("s#{i}", metadata: {"userAgent" => CHROME_UA}) }

        result = Segmenter.new(@store, browser: "Chrome").matching(limit: 10, offset: 0)

        refute result[:has_next]
        assert_equal 3, result[:sessions].size
      end

      def test_truncation_flag_when_scan_cap_hit
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 2)
        3.times { |i| seed_session("s#{i}", metadata: {"userAgent" => CHROME_UA}) }

        result = Segmenter.new(@store, browser: "Chrome").matching

        assert result[:was_truncated]
      end

      # ── since / until_time ──

      def test_since_filter_excludes_older_sessions
        seed_session("now-session", metadata: {"userAgent" => CHROME_UA})

        in_window = Segmenter.new(@store, since: Time.now.to_f - 3600).matching
        out_of_window = Segmenter.new(@store, since: Time.now.to_f + 3600).matching

        assert_equal ["now-session"], ids(in_window)
        assert_empty ids(out_of_window)
      end

      def test_until_time_filter_excludes_later_sessions
        seed_session("now-session", metadata: {"userAgent" => CHROME_UA})

        in_window = Segmenter.new(@store, until_time: Time.now.to_f + 3600).matching
        out_of_window = Segmenter.new(@store, until_time: Time.now.to_f - 3600).matching

        assert_equal ["now-session"], ids(in_window)
        assert_empty ids(out_of_window)
      end

      def test_time_bounds_compose_with_other_filters
        seed_session("chrome", metadata: {"userAgent" => CHROME_UA})
        seed_session("firefox", metadata: {"userAgent" => FIREFOX_UA})

        result = Segmenter.new(@store, browser: "Chrome",
          since: Time.now.to_f - 3600, until_time: Time.now.to_f + 3600).matching

        assert_equal ["chrome"], ids(result)
      end

      private

      def result(hash, key)
        hash[key]
      end
    end
  end
end
