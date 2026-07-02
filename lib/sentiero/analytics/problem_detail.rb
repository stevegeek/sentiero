# frozen_string_literal: true

require "date"

module Sentiero
  module Analytics
    # Aggregations for the problem detail page: facet distributions over the
    # already-fetched occurrences/session summaries, and the occurrence trend.
    # The trend's rolling counts query the store (count_occurrences); the facets
    # and the sparkline buckets are computed purely from the passed-in rows.
    class ProblemDetail
      # Rows shown per facet group on the problem detail page.
      FACET_LIMIT = 8

      # Day buckets in the problem-detail occurrence sparkline.
      TREND_DAYS = 30

      def initialize(store)
        @store = store
      end

      def facets(occurrences, session_summaries)
        paths = Hash.new(0)
        environments = Hash.new(0)
        releases = {}
        browsers = Hash.new(0)

        occurrences.each do |occ|
          ctx = occ["context"]
          next unless ctx.is_a?(Hash)
          tally_facet(paths, ctx.dig("request", "path"))
          tally_facet(environments, ctx["environment"])
          tally_release(releases, ctx["release"], occ["timestamp"])
        end

        session_summaries.each { |s| tally_facet(browsers, s[:browser]) }

        {
          paths: top_facet(paths),
          environments: top_facet(environments),
          releases: releases.sort_by { |_release, info| -info[:count] }.first(FACET_LIMIT),
          browsers: top_facet(browsers),
          sample_size: occurrences.size
        }
      end

      # The 24h/7d/30d header counts are exact (count_occurrences after:); the
      # sparkline buckets the already-fetched occurrences by UTC day, labeled
      # with its sample size.
      def trend(problem_id, occurrences)
        now = Time.now.to_f
        per_day = Hash.new(0)
        occurrences.each do |occ|
          ts = occ["timestamp"]&.to_f
          next unless ts && ts > 0
          per_day[Time.at(ts).utc.to_date.to_s] += 1
        end

        end_date = Time.now.utc.to_date
        series = ((end_date - (TREND_DAYS - 1))..end_date).map do |date|
          {date: date.to_s, count: per_day[date.to_s]}
        end

        {
          series: series,
          sample_size: occurrences.size,
          last_24h: occurrence_count_after(problem_id, now - 86_400),
          last_7d: occurrence_count_after(problem_id, now - 7 * 86_400),
          last_30d: occurrence_count_after(problem_id, now - TREND_DAYS * 86_400)
        }
      end

      private

      def occurrence_count_after(problem_id, after)
        @store.count_occurrences(problem_id, after: after)
      end

      def tally_facet(counts, value)
        counts[value] += 1 if value.is_a?(String) && !value.empty?
      end

      def tally_release(releases, release, timestamp)
        return unless release.is_a?(String) && !release.empty?

        info = releases[release] ||= {count: 0, first_seen: nil}
        info[:count] += 1
        ts = timestamp&.to_f
        info[:first_seen] = [info[:first_seen], ts].compact.min if ts && ts > 0
      end

      def top_facet(counts)
        counts.sort_by { |_value, count| -count }.first(FACET_LIMIT)
      end
    end
  end
end
