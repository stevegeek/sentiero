# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/stats_aggregator"

module Sentiero
  module Analytics
    class StatsAggregatorTest < Minitest::Test
      CHROME_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
      SAFARI_IPHONE_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

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

      # ── empty store ──

      def test_empty_store_returns_zeroed_result
        result = StatsAggregator.new(@store).aggregate

        assert_equal 0, result[:total_sessions]
        assert_equal 0, result[:total_events]
        assert_equal 0, result[:sessions_scanned]
        assert_nil result[:avg_duration_ms]
        assert_empty result[:browser_distribution]
        assert_empty result[:device_distribution]
        assert_empty result[:top_entry_pages]
        assert_empty result[:top_referrers]
        assert_empty result[:custom_event_tags]
        refute result[:was_truncated]
      end

      def test_empty_store_has_all_keys
        result = StatsAggregator.new(@store).aggregate

        %i[event_type_breakdown browser_distribution
          device_distribution top_entry_pages top_referrers
          session_duration_buckets custom_event_tags browser_event_tags
          events_per_day_series
          total_sessions total_events avg_duration_ms sessions_scanned
          was_truncated].each do |key|
          assert result.key?(key), "expected result to include #{key}"
        end
      end

      def test_empty_store_duration_buckets_present_and_zeroed
        result = StatsAggregator.new(@store).aggregate

        buckets = result[:session_duration_buckets]
        assert_equal %w[0-30s 30s-2m 2-5m 5-15m 15m+], buckets.keys
        assert(buckets.values.all?(&:zero?))
      end

      # ── event type / source breakdown ──

      def test_event_type_and_source_breakdown
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          {"type" => 3, "timestamp" => now_ms},
          {"type" => 3, "timestamp" => now_ms + 10},
          {"type" => 4, "timestamp" => now_ms + 20},
          {"type" => 5, "timestamp" => now_ms + 30, "data" => {"tag" => "click"}}
        ])

        result = StatsAggregator.new(@store).aggregate

        assert_equal 2, result[:event_type_breakdown][:incremental]
        assert_equal 1, result[:event_type_breakdown][:meta]
        assert_equal 1, result[:event_type_breakdown][:custom]

        assert_equal 1, result[:total_sessions]
        assert_equal 4, result[:total_events]
      end

      # ── custom event tags ──

      def test_custom_event_tags_tallied
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          {"type" => 5, "timestamp" => now_ms, "data" => {"tag" => "impression"}},
          {"type" => 5, "timestamp" => now_ms + 1, "data" => {"tag" => "impression"}},
          {"type" => 5, "timestamp" => now_ms + 2, "data" => {"tag" => "click"}},
          {"type" => 5, "timestamp" => now_ms + 3, "data" => {"payload" => "no tag"}}
        ])

        tags = StatsAggregator.new(@store).aggregate[:custom_event_tags]

        assert_equal 2, tags["impression"]
        assert_equal 1, tags["click"]
        refute tags.key?(nil)
      end

      def test_non_string_custom_tags_ignored
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          {"type" => 5, "timestamp" => now_ms, "data" => {"tag" => 42}},
          {"type" => 5, "timestamp" => now_ms + 1, "data" => {"tag" => "ok"}}
        ])

        tags = StatsAggregator.new(@store).aggregate[:custom_event_tags]

        assert_equal({"ok" => 1}, tags)
      end

      def test_browser_event_tags_tallied_from_type_5_non_error_events
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          {"type" => 5, "timestamp" => now_ms, "data" => {"tag" => "checkout"}},
          {"type" => 5, "timestamp" => now_ms + 1, "data" => {"tag" => "checkout"}},
          {"type" => 5, "timestamp" => now_ms + 2, "data" => {"tag" => "error", "payload" => {"message" => "boom"}}},
          {"type" => 5, "timestamp" => now_ms + 3, "data" => {"payload" => "no tag"}}
        ])

        result = StatsAggregator.new(@store).aggregate

        # Browser-origin tags: type-5 custom events, excluding the "error" tag
        # (mirrors BrowserEventDiscovery#browser_event?).
        assert_equal 2, result[:browser_event_tags]["checkout"]
        refute result[:browser_event_tags].key?("error")
        refute result[:browser_event_tags].key?(nil)

        # C5: "error" has its own surface (/issues?source=client) and is
        # excluded from the custom-tags panel too.
        refute result[:custom_event_tags].key?("error")
      end

      # ── C5(a): internal-tag exclusion + per-tag day series ──

      def test_custom_event_tags_exclude_internal_recorder_tags
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          {"type" => 5, "timestamp" => now_ms, "data" => {"tag" => "checkout"}},
          {"type" => 5, "timestamp" => now_ms + 1, "data" => {"tag" => "__perf", "payload" => {"metric" => "LCP", "value" => 1}}},
          {"type" => 5, "timestamp" => now_ms + 2, "data" => {"tag" => "__click", "payload" => {"selector" => "a"}}},
          {"type" => 5, "timestamp" => now_ms + 3, "data" => {"tag" => "__anything"}},
          {"type" => 5, "timestamp" => now_ms + 4, "data" => {"tag" => "error", "payload" => {"message" => "boom"}}}
        ])

        result = StatsAggregator.new(@store).aggregate

        assert_equal({"checkout" => 1}, result[:custom_event_tags])
        refute result[:browser_event_tags].key?("__perf")
        refute result[:browser_event_tags].key?("__click")
        # ...but the events still count toward the totals and error stats.
        assert_equal 5, result[:event_type_breakdown][:custom]
        assert_equal 1, result[:events_per_day_series].last[:error_count]
      end

      def test_custom_event_tag_series_aligns_with_day_series
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          {"type" => 5, "timestamp" => now_ms, "data" => {"tag" => "checkout"}},
          {"type" => 5, "timestamp" => now_ms + 1, "data" => {"tag" => "checkout"}},
          {"type" => 5, "timestamp" => now_ms + 2, "data" => {"tag" => "signup"}}
        ])

        result = StatsAggregator.new(@store).aggregate(range_days: 14)
        series = result[:custom_event_tag_series]

        checkout = series["checkout"]
        assert_equal 14, checkout.size
        assert_equal result[:events_per_day_series].map { |d| d[:date] },
          checkout.map { |d| d[:date] }
        assert_equal 2, checkout.last[:count]
        assert_equal 0, checkout.first[:count]
        assert_equal 1, series["signup"].last[:count]
      end

      def test_custom_event_tag_series_buckets_by_week_on_long_spans
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          {"type" => 5, "timestamp" => now_ms, "data" => {"tag" => "checkout"}}
        ])

        result = StatsAggregator.new(@store).aggregate(range_days: 90)
        checkout = result[:custom_event_tag_series]["checkout"]

        assert_equal result[:events_per_day_series].map { |d| d[:date] },
          checkout.map { |d| d[:date] }
        week_label = Time.now.utc.strftime("%G-W%V")
        assert_equal 1, checkout.find { |d| d[:date] == week_label }[:count]
      end

      def test_custom_event_tag_series_covers_only_top_tags
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"),
          25.times.map { |i| {"type" => 5, "timestamp" => now_ms + i, "data" => {"tag" => "tag#{format("%02d", i)}"}} })

        result = StatsAggregator.new(@store).aggregate

        assert_equal result[:custom_event_tags].keys.sort,
          result[:custom_event_tag_series].keys.sort
        assert_equal StatsAggregator::TOP_TAGS_LIMIT, result[:custom_event_tag_series].size
      end

      # ── browser / device distribution ──

      def test_browser_and_device_distribution_from_metadata
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("s1", {"userAgent" => CHROME_UA})
        @store.save_events(Sentiero::WindowRef.new("s2", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("s2", {"userAgent" => SAFARI_IPHONE_UA})

        result = StatsAggregator.new(@store).aggregate

        assert_equal 1, result[:browser_distribution]["Chrome"]
        assert_equal 1, result[:browser_distribution]["Safari"]
        assert_equal 1, result[:device_distribution]["Desktop"]
        assert_equal 1, result[:device_distribution]["Mobile"]
      end

      def test_sessions_without_user_agent_skipped_in_distributions
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"type" => 3, "timestamp" => now_ms}])

        result = StatsAggregator.new(@store).aggregate

        assert_empty result[:browser_distribution]
        assert_empty result[:device_distribution]
      end

      # ── entry pages / referrers ──

      def test_top_entry_pages_and_referrers
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("s1", {"entry_url" => "https://ex.com/a", "entry_referrer" => "https://google.com/"})
        @store.save_events(Sentiero::WindowRef.new("s2", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("s2", {"entry_url" => "https://ex.com/a", "entry_referrer" => "https://google.com/"})
        @store.save_events(Sentiero::WindowRef.new("s3", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("s3", {"entry_url" => "https://ex.com/b"})

        result = StatsAggregator.new(@store).aggregate

        top_page = result[:top_entry_pages].first
        assert_equal "https://ex.com/a", top_page[:url]
        assert_equal 2, top_page[:count]

        top_ref = result[:top_referrers].first
        assert_equal "https://google.com/", top_ref[:referrer]
        assert_equal 2, top_ref[:count]
      end

      # ── A3: entry pages from the first Meta href ──

      def meta_event(href, ts)
        {"type" => 4, "timestamp" => ts, "data" => {"href" => href, "width" => 1280, "height" => 800}}
      end

      def test_entry_page_comes_from_the_windows_first_meta_href
        # The S1/S3 ground-truth shape: the window entered on / and exited on
        # /app; the recorder overwrote metadata.url with the LAST page. The
        # entry panel must say /, not /app.
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          meta_event("https://ex.com/", now_ms),
          meta_event("https://ex.com/signup", now_ms + 10),
          meta_event("https://ex.com/app", now_ms + 20)
        ])
        @store.save_metadata("s1", {"url" => "https://ex.com/app", "has_errors" => true})

        pages = StatsAggregator.new(@store).aggregate[:top_entry_pages]

        assert_equal 1, pages.size
        assert_equal "https://ex.com/", pages.first[:url]
        assert_equal 1, pages.first[:count]
        # The error correlation follows the ENTRY page too.
        assert_equal 1, pages.first[:error_count]
      end

      def test_entry_url_metadata_overrides_first_meta_href
        # B2: the recorder's immutable entry_url wins over both the first-Meta
        # derivation and the overwritten metadata.url — and entry_referrer is
        # the real external source, not the last internal navigation.
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          meta_event("https://ex.com/signup", now_ms),
          meta_event("https://ex.com/app", now_ms + 10)
        ])
        @store.save_metadata("s1", {
          "url" => "https://ex.com/app",
          "referrer" => "https://ex.com/signup",
          "entry_url" => "https://ex.com/",
          "entry_referrer" => "https://google.com/"
        })

        result = StatsAggregator.new(@store).aggregate

        assert_equal "https://ex.com/", result[:top_entry_pages].first[:url]
        assert_equal "https://google.com/", result[:top_referrers].first[:referrer]
      end

      def test_entry_metadata_keys_are_not_surfaced_as_custom_metadata
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("s1", {"entry_url" => "https://ex.com/", "entry_referrer" => "https://google.com/", "plan" => "pro"})

        keys = StatsAggregator.new(@store).aggregate[:metadata_distributions].map { |d| d[:key] }

        assert_includes keys, "plan"
        refute_includes keys, "entry_url"
        refute_includes keys, "entry_referrer"
      end

      def test_entry_page_uses_the_earliest_window_of_a_session
        # Two windows (e.g. two tabs); whichever the store yields first, the
        # entry page is the first Meta of the window that STARTED first.
        @store.save_events(Sentiero::WindowRef.new("s1", "w-late"), [
          meta_event("https://ex.com/pricing", now_ms + 60_000)
        ])
        @store.save_events(Sentiero::WindowRef.new("s1", "w-early"), [
          meta_event("https://ex.com/", now_ms)
        ])

        pages = StatsAggregator.new(@store).aggregate[:top_entry_pages]

        assert_equal [{url: "https://ex.com/", count: 1, error_count: 0}], pages
      end

      # ── A3: same-origin referrers dropped ──

      def test_same_origin_referrers_are_dropped
        # An in-site form POST stamps the site's own URL as document.referrer
        # on the next load; that is not an acquisition source. Ground truth:
        # 100% direct -> empty referrer panel.
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [meta_event("https://ex.com/", now_ms)])
        @store.save_metadata("s1", {"url" => "https://ex.com/app", "referrer" => "https://ex.com/app"})

        result = StatsAggregator.new(@store).aggregate

        assert_empty result[:top_referrers]
      end

      def test_cross_origin_referrers_are_kept
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [meta_event("https://ex.com/", now_ms)])
        @store.save_metadata("s1", {"referrer" => "https://news.ycombinator.com/item?id=1"})

        top = StatsAggregator.new(@store).aggregate[:top_referrers]

        assert_equal [{referrer: "https://news.ycombinator.com/item?id=1", count: 1}], top
      end

      def test_same_host_different_scheme_or_port_is_not_same_origin
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [meta_event("https://ex.com/", now_ms)])
        @store.save_metadata("s1", {"referrer" => "http://ex.com/old"})

        top = StatsAggregator.new(@store).aggregate[:top_referrers]

        assert_equal "http://ex.com/old", top.first[:referrer]
      end

      def test_unparseable_referrers_are_kept
        # A referrer that does not parse as a URI cannot be proven internal —
        # keep it rather than silently hiding it.
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [meta_event("https://ex.com/", now_ms)])
        @store.save_metadata("s1", {"referrer" => "not a uri ::%"})

        top = StatsAggregator.new(@store).aggregate[:top_referrers]

        assert_equal 1, top.size
      end

      # ── B6: entry-page error correlation ──

      def test_top_entry_pages_carry_error_counts_from_same_pass
        @store.save_events(Sentiero::WindowRef.new("e1", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("e1", {"entry_url" => "https://ex.com/a", "has_errors" => true})
        @store.save_events(Sentiero::WindowRef.new("e2", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("e2", {"entry_url" => "https://ex.com/a"})
        @store.save_events(Sentiero::WindowRef.new("e3", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("e3", {"entry_url" => "https://ex.com/b"})

        pages = StatsAggregator.new(@store).aggregate[:top_entry_pages]

        row_a = pages.find { |row| row[:url] == "https://ex.com/a" }
        assert_equal 2, row_a[:count]
        assert_equal 1, row_a[:error_count]
        row_b = pages.find { |row| row[:url] == "https://ex.com/b" }
        assert_equal 0, row_b[:error_count]
      end

      def test_top_lists_capped
        25.times do |i|
          @store.save_events(Sentiero::WindowRef.new("s#{i}", "w1"), [{"type" => 3, "timestamp" => now_ms}])
          @store.save_metadata("s#{i}", {"entry_url" => "https://ex.com/p#{i}", "entry_referrer" => "https://r#{i}.com/"})
        end

        result = StatsAggregator.new(@store).aggregate

        assert_equal 10, result[:top_entry_pages].size
        assert_equal 10, result[:top_referrers].size
      end

      # ── duration buckets ──

      def test_duration_buckets_classify
        seed_session_with_duration("d0", 10_000)      # 10s -> 0-30s
        seed_session_with_duration("d1", 60_000)      # 60s -> 30s-2m
        seed_session_with_duration("d2", 200_000)     # 200s -> 2-5m
        seed_session_with_duration("d3", 600_000)     # 10m -> 5-15m
        seed_session_with_duration("d4", 1_200_000)   # 20m -> 15m+

        buckets = StatsAggregator.new(@store).aggregate[:session_duration_buckets]

        assert_equal 1, buckets["0-30s"]
        assert_equal 1, buckets["30s-2m"]
        assert_equal 1, buckets["2-5m"]
        assert_equal 1, buckets["5-15m"]
        assert_equal 1, buckets["15m+"]
      end

      # ── time series ──

      def test_events_per_day_series_covers_requested_range
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"type" => 3, "timestamp" => now_ms}])

        series = StatsAggregator.new(@store).aggregate(range_days: 14)[:events_per_day_series]

        assert_equal 14, series.size
        assert series.all? { |d| d.key?(:date) && d.key?(:event_count) && d.key?(:session_count) }
        # today is the last entry; it includes the session we just saved
        today = series.last
        assert_equal Time.now.utc.to_date.to_s, today[:date]
        assert_equal 1, today[:session_count]
        assert_equal 1, today[:event_count]
      end

      def test_per_day_error_count_tallied_in_series
        # type==5, data.tag=="error" is a browser JS error
        @store.save_events(Sentiero::WindowRef.new("s-err", "w1"), [
          {"type" => 3, "timestamp" => now_ms},
          {"type" => 5, "timestamp" => now_ms + 50, "data" => {"tag" => "error", "payload" => {"message" => "Boom"}}},
          {"type" => 5, "timestamp" => now_ms + 100, "data" => {"tag" => "error", "payload" => {"message" => "Boom2"}}}
        ])
        # type==5 with a different tag is NOT an error
        @store.save_events(Sentiero::WindowRef.new("s-click", "w1"), [
          {"type" => 5, "timestamp" => now_ms, "data" => {"tag" => "click"}}
        ])

        series = StatsAggregator.new(@store).aggregate[:events_per_day_series]
        today = series.last

        assert_equal 2, today[:error_count]
      end

      def test_per_day_error_count_zero_when_no_errors
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"type" => 3, "timestamp" => now_ms}])

        series = StatsAggregator.new(@store).aggregate[:events_per_day_series]
        today = series.last

        assert_equal 0, today[:error_count]
      end

      def test_range_days_controls_series_length
        assert_equal 30, StatsAggregator.new(@store).aggregate(range_days: 30)[:events_per_day_series].size
      end

      def test_90_day_preset_buckets_by_iso_week
        result = StatsAggregator.new(@store).aggregate(range_days: 90)
        series = result[:events_per_day_series]

        assert_equal "week", result[:series_bucket]
        assert series.all? { |entry| entry[:date].match?(/\A\d{4}-W\d{2}\z/) },
          "expected ISO-week labels, got #{series.map { |e| e[:date] }.inspect}"
        assert_operator series.size, :<=, 14
      end

      # ── custom since/until bounds ──

      def test_custom_bounds_exclude_sessions_outside_the_window
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"type" => 3, "timestamp" => now_ms}])

        result = StatsAggregator.new(@store).aggregate(
          since: Time.now.to_f - 7200, until_time: Time.now.to_f - 3600
        )

        assert_equal 0, result[:total_sessions]
        assert_equal 0, result[:total_events]
      end

      def test_custom_bounds_include_sessions_inside_the_window
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"type" => 3, "timestamp" => now_ms}])

        result = StatsAggregator.new(@store).aggregate(
          since: Time.now.to_f - 3600, until_time: Time.now.to_f + 3600
        )

        assert_equal 1, result[:total_sessions]
        assert_equal 1, result[:total_events]
      end

      def test_out_of_window_events_from_in_range_sessions_are_clamped
        # The session was updated now (in range), but carries an event recorded
        # 10 days before the window opened. That event must not inflate the
        # totals or leak into the day buckets.
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          {"type" => 3, "timestamp" => now_ms},
          {"type" => 3, "timestamp" => now_ms - 10 * 86_400_000}
        ])

        result = StatsAggregator.new(@store).aggregate(since: Time.now.to_f - 2 * 86_400)

        assert_equal 1, result[:total_events]
        assert_equal 1, result[:event_type_breakdown][:incremental]
      end

      def test_series_spans_the_custom_bounds
        series = StatsAggregator.new(@store).aggregate(
          since: Time.utc(2026, 3, 1).to_f,
          until_time: Time.utc(2026, 3, 10, 23, 59, 59).to_f
        )[:events_per_day_series]

        assert_equal 10, series.size
        assert_equal "2026-03-01", series.first[:date]
        assert_equal "2026-03-10", series.last[:date]
      end

      def test_week_buckets_for_custom_spans_over_45_days
        result = StatsAggregator.new(@store).aggregate(
          since: Time.utc(2026, 1, 1).to_f,
          until_time: Time.utc(2026, 3, 1).to_f
        )

        assert_equal "week", result[:series_bucket]
        series = result[:events_per_day_series]
        assert_equal "2026-W01", series.first[:date]
        assert_equal "2026-W09", series.last[:date]
      end

      def test_events_land_in_their_iso_week_bucket
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"type" => 3, "timestamp" => now_ms}])

        result = StatsAggregator.new(@store).aggregate(since: Time.now.to_f - 59 * 86_400)
        week_label = Time.now.utc.strftime("%G-W%V")
        bucket = result[:events_per_day_series].find { |entry| entry[:date] == week_label }

        refute_nil bucket, "expected a bucket for the current ISO week"
        assert_equal 1, bucket[:event_count]
        assert_equal 1, bucket[:session_count]
      end

      def test_daily_series_reports_day_bucket
        result = StatsAggregator.new(@store).aggregate(range_days: 30)

        assert_equal "day", result[:series_bucket]
      end

      # ── C4: effective window bounds exposed for period-over-period math ──

      def test_result_exposes_effective_window_bounds
        since = Time.utc(2026, 3, 1).to_f
        until_time = Time.utc(2026, 3, 10).to_f

        result = StatsAggregator.new(@store).aggregate(since: since, until_time: until_time)

        assert_equal since, result[:window_since]
        assert_equal until_time, result[:window_until]
      end

      def test_window_bounds_default_to_preset_start_and_now
        before = Time.now.to_f
        result = StatsAggregator.new(@store).aggregate(range_days: 14)
        after = Time.now.to_f

        start_date = Time.now.utc.to_date - 13
        assert_equal Time.utc(start_date.year, start_date.month, start_date.day).to_f,
          result[:window_since]
        assert_operator result[:window_until], :>=, before
        assert_operator result[:window_until], :<=, after
      end

      # ── B8: navigation report ──

      def seed_navigation(session_id, payloads)
        events = [{"type" => 3, "timestamp" => now_ms}]
        payloads.each_with_index do |payload, i|
          events << {"type" => 5, "timestamp" => now_ms + i + 1,
                     "data" => {"tag" => "navigation", "payload" => payload}}
        end
        @store.save_events(Sentiero::WindowRef.new(session_id, "w1"), events)
      end

      def test_navigation_destinations_split_internal_external
        seed_navigation("n1", [
          {"url" => "https://ex.com/pricing", "text" => "Pricing"},
          {"url" => "https://ex.com/pricing", "text" => "Pricing"},
          {"url" => "https://partner.test/", "text" => "Partner", "external" => true}
        ])

        nav = StatsAggregator.new(@store).aggregate[:navigation]

        internal = nav[:internal].first
        assert_equal "https://ex.com/pricing", internal[:url]
        assert_equal 2, internal[:count]
        external = nav[:external].first
        assert_equal "https://partner.test/", external[:url]
        assert_equal 1, external[:count]
      end

      def test_navigation_top_link_texts_tallied
        seed_navigation("n1", [
          {"url" => "https://ex.com/a", "text" => "Read more"},
          {"url" => "https://ex.com/b", "text" => "Read more"}
        ])

        top_text = StatsAggregator.new(@store).aggregate[:navigation][:top_texts].first

        assert_equal "Read more", top_text[:text]
        assert_equal 2, top_text[:count]
      end

      def test_navigation_ignores_malformed_payloads
        seed_navigation("n1", ["nope", {}, {"url" => 42}])

        nav = StatsAggregator.new(@store).aggregate[:navigation]

        assert_empty nav[:internal]
        assert_empty nav[:external]
        assert_empty nav[:top_texts]
      end

      # ── B9: session metadata key/value distributions ──

      def seed_session_with_metadata(session_id, metadata)
        @store.save_events(Sentiero::WindowRef.new(session_id, "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata(session_id, metadata)
      end

      def test_metadata_distributions_tally_custom_keys_with_top_values
        seed_session_with_metadata("m1", {"plan" => "pro", "userAgent" => CHROME_UA})
        seed_session_with_metadata("m2", {"plan" => "pro"})
        seed_session_with_metadata("m3", {"plan" => "free"})

        dist = StatsAggregator.new(@store).aggregate[:metadata_distributions]

        plan = dist.find { |entry| entry[:key] == "plan" }
        assert_equal 3, plan[:count]
        assert_equal({value: "pro", count: 2}, plan[:values].first)
        assert_includes plan[:values], {value: "free", count: 1}
      end

      def test_metadata_distributions_exclude_recorder_internal_keys
        seed_session_with_metadata("m1", {"userAgent" => CHROME_UA,
          "url" => "https://ex.com/", "referrer" => "https://google.com/",
          "viewport" => "1024x768", "has_errors" => true})

        assert_empty StatsAggregator.new(@store).aggregate[:metadata_distributions]
      end

      def test_metadata_key_counting_continues_past_value_cap
        cap = StatsAggregator::MAX_METADATA_VALUES_PER_KEY
        (cap + 5).times { |i| seed_session_with_metadata("m#{i}", {"uid" => "u#{i}"}) }

        dist = StatsAggregator.new(@store).aggregate[:metadata_distributions]

        uid = dist.find { |entry| entry[:key] == "uid" }
        # Distinct VALUES tracked per key are bounded, but the key's session
        # count keeps climbing.
        assert_equal cap + 5, uid[:count]
      end

      # ── C6(b): bounded server-exception overlay ──

      def seed_occurrence(fingerprint, timestamp)
        @store.save_occurrence({"fingerprint" => fingerprint, "project" => "app",
          "exception_class" => "E", "message" => "boom", "timestamp" => timestamp})
      end

      def test_series_includes_server_occurrences_per_day_when_overlay_requested
        2.times { seed_occurrence("fp_a", Time.now.to_f) }
        seed_occurrence("fp_b", Time.now.to_f)

        result = StatsAggregator.new(@store).aggregate(server_exception_overlay: true)

        assert_equal 3, result[:events_per_day_series].last[:server_error_count]
        refute result[:server_overlay_truncated]
      end

      def test_server_overlay_not_fetched_by_default
        seed_occurrence("fp_a", Time.now.to_f)

        result = StatsAggregator.new(@store).aggregate

        assert_equal 0, result[:events_per_day_series].last[:server_error_count]
        refute result[:server_overlay_truncated]
      end

      def test_server_overlay_buckets_occurrences_by_utc_day
        seed_occurrence("fp_a", Time.now.to_f)
        seed_occurrence("fp_a", Time.now.to_f - 86_400)

        series = StatsAggregator.new(@store)
          .aggregate(server_exception_overlay: true)[:events_per_day_series]

        today = Time.now.utc.to_date.to_s
        yesterday = (Time.now.utc.to_date - 1).to_s
        assert_equal 1, series.find { |d| d[:date] == today }[:server_error_count]
        assert_equal 1, series.find { |d| d[:date] == yesterday }[:server_error_count]
      end

      def test_server_overlay_excludes_occurrences_outside_the_window
        seed_occurrence("fp_a", Time.now.to_f)
        seed_occurrence("fp_a", Time.now.to_f - 10 * 86_400)

        result = StatsAggregator.new(@store).aggregate(
          since: Time.now.to_f - 2 * 86_400, server_exception_overlay: true
        )

        total = result[:events_per_day_series].sum { |d| d[:server_error_count] }
        assert_equal 1, total
      end

      def test_server_overlay_lands_in_week_buckets_on_long_spans
        seed_occurrence("fp_a", Time.now.to_f)

        result = StatsAggregator.new(@store).aggregate(
          since: Time.now.to_f - 59 * 86_400, server_exception_overlay: true
        )

        week_label = Time.now.utc.strftime("%G-W%V")
        bucket = result[:events_per_day_series].find { |d| d[:date] == week_label }
        assert_equal 1, bucket[:server_error_count]
      end

      def test_server_overlay_occurrence_cap_flags_truncation
        StatsAggregator::MAX_OCCURRENCES_PER_PROBLEM.times do |i|
          seed_occurrence("fp_busy", Time.now.to_f - i)
        end

        result = StatsAggregator.new(@store).aggregate(server_exception_overlay: true)

        assert result[:server_overlay_truncated]
      end

      def test_server_overlay_problem_cap_flags_truncation
        StatsAggregator::MAX_OVERLAY_PROBLEMS.times do |i|
          seed_occurrence("fp_cap_#{i}", Time.now.to_f)
        end

        result = StatsAggregator.new(@store).aggregate(server_exception_overlay: true)

        assert result[:server_overlay_truncated]
        # tallied counts stop at the problem cap — a lower bound, never a guess
        assert_equal StatsAggregator::MAX_OVERLAY_PROBLEMS,
          result[:events_per_day_series].sum { |d| d[:server_error_count] }
      end

      # ── B3: top problems with "new this period" flag ──

      def save_problem(fingerprint, message, timestamp, count: 1)
        count.times do |i|
          @store.save_occurrence({"fingerprint" => fingerprint, "project" => "app",
            "exception_class" => "E", "message" => message, "timestamp" => timestamp + i})
        end
      end

      def test_top_problems_sorted_by_count_with_new_flag_from_window_since
        save_problem("fp_old", "old boom", Time.now.to_f - 60 * 86_400)
        save_problem("fp_new", "new boom", Time.now.to_f, count: 3)

        top = StatsAggregator.new(@store).aggregate[:top_problems]

        assert_equal "fp_new", top.first[:id]
        assert_equal 3, top.first[:count]
        assert top.first[:new], "first_seen inside the active window flags the problem as new"
        old_row = top.find { |p| p[:id] == "fp_old" }
        refute old_row[:new], "first_seen before the window must not be flagged new"
      end

      def test_top_problems_new_flag_honors_custom_since
        ts = Time.now.to_f - 60 * 86_400
        save_problem("fp_window", "windowed boom", ts)

        top = StatsAggregator.new(@store).aggregate(since: ts - 86_400)[:top_problems]

        assert top.first[:new], "a custom window covering first_seen makes the problem new"
      end

      def test_top_problems_excludes_non_open
        save_problem("fp_resolved", "resolved boom", Time.now.to_f)
        @store.update_problem_status("fp_resolved", "resolved")

        assert_empty StatsAggregator.new(@store).aggregate[:top_problems]
      end

      def test_top_problems_capped
        7.times { |i| save_problem("fp_cap_#{i}", "boom #{i}", Time.now.to_f) }

        top = StatsAggregator.new(@store).aggregate[:top_problems]

        assert_equal StatsAggregator::TOP_PROBLEMS_LIMIT, top.size
      end

      # ── truncation ──

      def test_not_truncated_under_limit
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"type" => 3, "timestamp" => now_ms}])

        result = StatsAggregator.new(@store).aggregate

        refute result[:was_truncated]
        assert_equal 1, result[:sessions_scanned]
      end

      def test_truncated_when_scan_cap_hit
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 2)
        3.times { |i| @store.save_events(Sentiero::WindowRef.new("s#{i}", "w1"), [{"type" => 3, "timestamp" => now_ms}]) }

        result = StatsAggregator.new(@store).aggregate

        assert result[:was_truncated]
        assert_equal 2, result[:sessions_scanned]
      end

      # ── H7: the store's own injected Limits win over the global config ──

      def test_honors_the_stores_own_scan_cap_over_the_global_config
        Sentiero.configuration.analytics_max_scan_sessions = 5000
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 2)
        3.times { |i| @store.save_events(Sentiero::WindowRef.new("s#{i}", "w1"), [{"type" => 3, "timestamp" => now_ms}]) }

        result = StatsAggregator.new(@store).aggregate

        assert result[:was_truncated]
        assert_equal 2, result[:sessions_scanned]
      end

      # ── aggregate_with_prior: single widened scan for deltas ──

      # Counts each_session_events calls so we can prove the overview makes one
      # pass, not two.
      class CountingMemory < Stores::Memory
        attr_reader :scan_count

        def initialize(*)
          super
          @scan_count = 0
        end

        def each_session_events(**kwargs, &block)
          @scan_count += 1 if block
          super
        end
      end

      def test_aggregate_with_prior_issues_a_single_scan
        store = CountingMemory.new
        Sentiero.configuration.store = store
        base = Time.now.to_f
        store.save_events(Sentiero::WindowRef.new("cur", "w1"), [{"type" => 3, "timestamp" => (base * 1000).round}])
        seed_at(store, "old", base - 3600)

        result = StatsAggregator.new(store).aggregate_with_prior(since: base - 1800, until_time: base + 1800)

        assert_equal 1, store.scan_count, "expected exactly one each_session_events scan"
        refute_nil result[:prior], "prior aggregate should be present when deltas are computable"
      end

      def test_aggregate_with_prior_matches_two_separate_passes
        base = Time.now.to_f
        since = base - 1800
        until_time = base + 1800
        span = until_time - since

        # Current window: two sessions, one with an error.
        @store.save_events(Sentiero::WindowRef.new("cur1", "w1"),
          [{"type" => 3, "timestamp" => (base * 1000).round}, {"type" => 4, "timestamp" => (base * 1000).round + 1}])
        @store.save_events(Sentiero::WindowRef.new("cur2", "w1"), [{"type" => 3, "timestamp" => (base * 1000).round}])
        @store.save_metadata("cur2", {"has_errors" => true})
        # Prior window: one session.
        seed_at(@store, "prior1", base - 3600)

        aggregator = StatsAggregator.new(@store)
        combined = aggregator.aggregate_with_prior(since: since, until_time: until_time)

        old_current = aggregator.aggregate(since: since, until_time: until_time, server_exception_overlay: true)
        old_prior = aggregator.aggregate(since: since - span, until_time: since - 0.001)

        %i[total_sessions total_events sessions_with_errors].each do |key|
          assert_equal old_current[key], combined[:current][key], "current #{key} must match the single-window pass"
          assert_equal old_prior[key], combined[:prior][key], "prior #{key} must match the prior-window pass"
        end
      end

      def test_aggregate_with_prior_falls_back_to_exact_current_when_truncated
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 1)
        base = Time.now.to_f
        @store.save_events(Sentiero::WindowRef.new("cur", "w1"), [{"type" => 3, "timestamp" => (base * 1000).round}])
        seed_at(@store, "old", base - 3600)

        aggregator = StatsAggregator.new(@store)
        combined = aggregator.aggregate_with_prior(since: base - 1800, until_time: base + 1800)

        # Truncated widened scan drops deltas but the current numbers must still
        # equal an exact single-window scan.
        assert_nil combined[:prior]
        assert combined[:current][:was_truncated]
        exact = aggregator.aggregate(since: base - 1800, until_time: base + 1800, server_exception_overlay: true)
        assert_equal exact[:total_sessions], combined[:current][:total_sessions]
      end

      def test_aggregate_with_prior_skips_prior_for_zero_length_window
        base = Time.now.to_f
        combined = StatsAggregator.new(@store).aggregate_with_prior(since: base, until_time: base)

        assert_nil combined[:prior]
        refute_nil combined[:current]
      end

      private

      def seed_at(store, id, epoch_seconds)
        Time.stub(:now, Time.at(epoch_seconds)) do
          store.save_events(Sentiero::WindowRef.new(id, "w1"), [{"type" => 3, "timestamp" => (epoch_seconds * 1000).round}])
        end
      end

      def seed_session_with_duration(id, duration_ms)
        @store.save_events(Sentiero::WindowRef.new(id, "w1"), [
          {"type" => 3, "timestamp" => now_ms},
          {"type" => 3, "timestamp" => now_ms + duration_ms}
        ])
      end
    end
  end
end
