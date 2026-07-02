# frozen_string_literal: true

require_relative "../events"
require_relative "../stats"

module Sentiero
  module Analytics
    # Per-segment web-vitals accumulator. The recorder emits one "__perf" custom
    # event per metric report, with data.payload {metric, value, rating}.
    #
    # Within a single segment, multiple reports for the same metric collapse to
    # the LAST (the web-vitals library re-reports as the page evolves; only the
    # final report is authoritative). Samples accumulate across all segments.
    #
    # #summarize's worst carries :value too; PageReportAnalyzer strips it afterward.
    class VitalsCollector
      include Events
      include Stats

      # Recorder tag for a web-vitals report.
      PERF_TAG = "__perf"

      attr_reader :capped

      # max_samples: nil unbounded; an Integer caps each metric's values, flipping #capped.
      def initialize(max_samples: nil)
        @max_samples = max_samples
        @metrics = {} # metric => {values:, ratings:, worst:}
        @capped = false
      end

      # session_id/window_id/anchor attribute the worst (highest-value) sample.
      # anchor is the window's first-event timestamp; offset_ms is relative to it
      # so replay deep-links target the window start, not the segment.
      def collect(segment, session_id:, window_id:, anchor:)
        samples = {}
        segment.each do |event|
          sample = parse_sample(event)
          samples[sample[:metric]] = sample if sample
        end

        samples.each_value do |sample|
          entry = @metrics[sample[:metric]] ||= {values: [], ratings: Hash.new(0), worst: nil}
          if @max_samples && entry[:values].size >= @max_samples
            @capped = true
            next
          end

          entry[:values] << sample[:value]

          rating = sample[:rating]
          entry[:ratings][rating] += 1 if rating.is_a?(String) && !rating.empty?

          if entry[:worst].nil? || sample[:value] > entry[:worst][:value]
            entry[:worst] = {
              session_id: session_id,
              window_id: window_id,
              offset_ms: offset_ms(anchor, sample[:timestamp]),
              value: sample[:value]
            }
          end
        end
      end

      def summarize
        summarized = @metrics.transform_values { |entry| summarize_metric(entry) }
        {
          sample_count: summarized.values.sum { |m| m[:samples] },
          metrics: summarized
        }
      end

      private

      def parse_sample(event)
        return nil unless event["type"] == CUSTOM

        data = event["data"]
        return nil unless data.is_a?(Hash) && data["tag"] == PERF_TAG

        payload = data["payload"]
        return nil unless payload.is_a?(Hash)

        metric = payload["metric"]
        value = payload["value"]
        return nil unless metric.is_a?(String) && !metric.empty? && value.is_a?(Numeric)

        {metric: metric, value: value, rating: payload["rating"], timestamp: event["timestamp"]}
      end

      def summarize_metric(entry)
        sorted = entry[:values].sort
        {
          samples: sorted.size,
          p50: percentile(sorted, 50),
          p75: percentile(sorted, 75),
          p90: percentile(sorted, 90),
          ratings: entry[:ratings],
          worst: entry[:worst]
        }
      end
    end
  end
end
