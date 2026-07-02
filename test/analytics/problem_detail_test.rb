# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/problem_detail"

module Sentiero
  module Analytics
    class ProblemDetailTest < Minitest::Test
      def setup
        @store = Stores::Memory.new
      end

      def detail = ProblemDetail.new(@store)

      def occ(path: nil, env: nil, release: nil, ts: Time.now.to_f)
        ctx = {}
        ctx["request"] = {"path" => path} if path
        ctx["environment"] = env if env
        ctx["release"] = release if release
        {"timestamp" => ts, "context" => ctx}
      end

      # ── facets ──

      def test_facets_aggregate_paths_environments_and_browsers
        occurrences = [
          occ(path: "/checkout", env: "production"),
          occ(path: "/checkout", env: "production"),
          occ(path: "/cart", env: "staging")
        ]
        summaries = [{browser: "Chrome"}, {browser: "Chrome"}, {browser: "Safari"}]

        facets = detail.facets(occurrences, summaries)
        assert_equal [["/checkout", 2], ["/cart", 1]], facets[:paths]
        assert_equal [["production", 2], ["staging", 1]], facets[:environments]
        assert_equal [["Chrome", 2], ["Safari", 1]], facets[:browsers]
        assert_equal 3, facets[:sample_size]
      end

      def test_facets_release_tracks_count_and_earliest_first_seen
        occurrences = [
          occ(release: "2.0.0", ts: 200.0),
          occ(release: "2.0.0", ts: 100.0)
        ]
        facets = detail.facets(occurrences, [])
        release, info = facets[:releases].first
        assert_equal "2.0.0", release
        assert_equal 2, info[:count]
        assert_in_delta 100.0, info[:first_seen]
      end

      def test_facets_ignore_blank_and_non_string_values
        facets = detail.facets([occ(path: "", env: nil)], [{browser: nil}])
        assert_empty facets[:paths]
        assert_empty facets[:environments]
        assert_empty facets[:browsers]
      end

      # ── trend ──

      def test_trend_buckets_passed_occurrences_by_utc_day
        now = Time.now.to_f
        occurrences = [occ(ts: now), occ(ts: now - 10)]
        series = detail.trend("fp", occurrences)[:series]
        assert_equal ProblemDetail::TREND_DAYS, series.size
        assert_equal 2, series.last[:count] # today carries both
        assert_equal 2, detail.trend("fp", occurrences)[:sample_size]
      end

      def test_trend_rolling_counts_query_the_store
        now = Time.now.to_f
        [now - 3600, now - 2 * 86_400, now - 10 * 86_400, now - 40 * 86_400].each do |ts|
          @store.save_occurrence({"fingerprint" => "fp", "project" => "app",
            "exception_class" => "E", "message" => "boom", "timestamp" => ts, "backtrace" => ["a:1"]})
        end

        trend = detail.trend("fp", [])
        assert_equal 1, trend[:last_24h]
        assert_equal 2, trend[:last_7d]
        assert_equal 3, trend[:last_30d]
      end
    end
  end
end
