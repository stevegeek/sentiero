# frozen_string_literal: true

module Sentiero
  module Analytics
    module Stats
      # Nearest-rank percentile; `sorted` must be pre-sorted and non-empty.
      def percentile(sorted, pct)
        rank = (pct / 100.0 * sorted.size).ceil
        sorted[rank.clamp(1, sorted.size) - 1]
      end

      def mean(values)
        values.sum.to_f / values.size
      end

      # Milliseconds from `anchor` to `timestamp`, floored at 0; 0 if either is nil.
      def offset_ms(anchor, timestamp)
        return 0 unless anchor && timestamp

        [timestamp - anchor, 0].max.round
      end

      # Top `limit` [key, count] pairs, highest count first, ties broken by key
      # so the ordering is deterministic.
      def top_counts(counts, limit:)
        counts.sort_by { |key, count| [-count, key] }.first(limit)
      end
    end
  end
end
