# frozen_string_literal: true

require "test_helper"
require "tmpdir"

begin
  require "sqlite3"
  SQLITE_AVAILABLE = true unless defined?(SQLITE_AVAILABLE)
rescue LoadError
  SQLITE_AVAILABLE = false unless defined?(SQLITE_AVAILABLE)
end

require "sentiero/stores/sqlite" if SQLITE_AVAILABLE
require "sentiero/analytics/stats_aggregator"
require "sentiero/analytics/page_report_analyzer"
require "sentiero/analytics/scroll_depth_analyzer"
require "sentiero/analytics/web_vitals_analyzer"
require "sentiero/analytics/frustration_analyzer"
require "sentiero/analytics/funnel_analyzer"
require "sentiero/analytics/conversion_analyzer"
require "sentiero/analytics/heatmap_analyzer"
require "sentiero/analytics/engagement_analyzer"
require "sentiero/analytics/browser_event_discovery"
require "sentiero/analytics/error_discovery"
require "sentiero/analytics/exporter"

module Sentiero
  module Analytics
    # DOM snapshots dominate stored bytes and (FormAnalyzer aside) no
    # analytics page reads them. Every analyzer here must run on a store whose
    # snapshot payloads are unreadable — success proves its scan filters them
    # out in SQL instead of parsing and discarding them.
    class TypedScanRegressionTest < Minitest::Test
      include SQLiteStoreTracking

      URL = "https://example.test/menu"

      def setup
        skip "sqlite3 gem not available" unless SQLITE_AVAILABLE
        @tmpdir = Dir.mktmpdir("sentiero_typed_scan")
        @store = open_sqlite_store(path: ::File.join(@tmpdir, "test.db"))

        t = Time.now.to_f * 1000
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          {"timestamp" => t, "type" => 4, "data" => {"href" => URL, "width" => 390, "height" => 844}},
          {"timestamp" => t + 10, "type" => 2, "data" => {"node" => {"childNodes" => []}}},
          {"timestamp" => t + 20, "type" => 3, "data" => {"source" => 3, "id" => 1, "x" => 0, "y" => 400}},
          {"timestamp" => t + 30, "type" => 3, "data" => {"source" => 5, "id" => 12, "text" => "x"}},
          {"timestamp" => t + 40, "type" => 3, "data" => {"source" => 2, "type" => 2, "id" => 9, "x" => 10, "y" => 20}},
          {"timestamp" => t + 50, "type" => 5, "data" => {"tag" => "navigation", "payload" => {"url" => "/menu"}}},
          {"timestamp" => t + 60, "type" => 5, "data" => {"tag" => "error", "payload" => {"message" => "boom"}}},
          {"timestamp" => t + 70, "type" => 5, "data" => {"tag" => "__click", "payload" => {"x" => 10, "y" => 20, "selector" => "a"}}}
        ])
        @store.save_metadata("s1", {"userAgent" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X)", "url" => URL})

        @store.send(:db).execute("UPDATE events SET data = '{corrupt' WHERE type = 2")
      end

      def teardown
        FileUtils.rm_rf(@tmpdir) if @tmpdir && ::File.directory?(@tmpdir)
      end

      def test_stats_aggregator_skips_snapshot_payloads_but_still_counts_them
        result = StatsAggregator.new(@store).aggregate(range_days: 7)

        assert_equal 8, result[:total_events]
        assert_equal({incremental: 3, meta: 1, custom: 3}, result[:event_type_breakdown])
        assert_equal 1, result[:custom_event_tags]["navigation"]
        assert_equal 8, result[:events_per_day_series].sum { |entry| entry[:event_count] }
      end

      def test_stats_aggregator_with_prior_window_skips_snapshot_payloads
        result = StatsAggregator.new(@store).aggregate_with_prior(range_days: 7)

        assert_equal 8, result[:current][:total_events]
      end

      def test_page_report_analyzer_skips_snapshot_payloads
        result = PageReportAnalyzer.new(@store).analyze(URL)

        assert result
      end

      def test_scroll_depth_analyzer_skips_snapshot_payloads
        result = ScrollDepthAnalyzer.new(@store).analyze

        assert_equal [URL], result[:pages].keys
      end

      def test_web_vitals_analyzer_skips_snapshot_payloads
        assert WebVitalsAnalyzer.new(@store).analyze
      end

      def test_frustration_analyzer_skips_snapshot_payloads
        assert FrustrationAnalyzer.new(@store).analyze
      end

      def test_funnel_analyzer_skips_snapshot_payloads
        assert FunnelAnalyzer.new(@store).analyze(%w[navigation])
      end

      def test_conversion_analyzer_skips_snapshot_payloads
        assert ConversionAnalyzer.new(@store).analyze("navigation")
      end

      def test_heatmap_analyzer_skips_snapshot_payloads
        assert_equal [URL], HeatmapAnalyzer.new(@store).recorded_urls
        assert HeatmapAnalyzer.new(@store).analyze(URL)
      end

      def test_engagement_analyzer_skips_snapshot_payloads
        assert EngagementAnalyzer.new(@store).analyze
      end

      def test_browser_event_discovery_skips_snapshot_payloads
        result = BrowserEventDiscovery.new(@store).recent_events

        assert(result[:rows].any? { |row| row[:name] == "navigation" })
      end

      def test_error_discovery_skips_snapshot_payloads
        result = ErrorDiscovery.new(@store).grouped_errors

        assert_equal ["boom"], result[:groups].map { |group| group[:message] }
      end

      def test_exporter_browser_events_table_skips_snapshot_payloads
        table = Exporter.new(@store).table("browser_events")

        assert(table[:rows].any? { |row| row.include?("navigation") })
      end
    end
  end
end
