# frozen_string_literal: true

require_relative "analyzer"
require_relative "frustration_analyzer"

module Sentiero
  module Analytics
    # Scores each session 0–100 on a STRUGGLE score (higher = more friction):
    # a weighted blend of eight signals, each saturating to 0.0..1.0 so one
    # pathological session can't dominate. Signals: rage_clicks, dead_clicks,
    # nav_churn, idle_ratio, thrashing_scroll, quick_bounce, form_refills,
    # error_abandonment.
    class EngagementAnalyzer < Analyzer
      # Signal weights; MUST sum to 1.00.
      WEIGHTS = {
        rage_clicks: 0.20,
        dead_clicks: 0.15,
        nav_churn: 0.15,
        idle_ratio: 0.10,
        thrashing_scroll: 0.10,
        quick_bounce: 0.10,
        form_refills: 0.10,
        error_abandonment: 0.10
      }.freeze

      RAGE_SATURATION = 3 # 3+ rage clusters → full rage sub-score
      DEAD_SATURATION = 3 # 3+ dead clicks → full dead sub-score
      NAV_CHURN_SATURATION = 3 # 3+ revisits to already-seen URLs → full sub-score
      THRASH_SATURATION = 3 # 3+ scroll reversals → full thrash sub-score
      REFILL_SATURATION = 2 # 2+ field re-fills → full refill sub-score
      IDLE_GAP_MS = 10_000 # consecutive events farther apart than this are "idle"
      THRASH_MIN_DELTA_PX = 100 # a scroll delta below this is too small to be thrashing
      THRASH_WINDOW_MS = 1_000 # both deltas of a reversal must fall within this span
      QUICK_BOUNCE_MS = 5_000 # single-page sessions shorter than this bounced
      ERROR_ABANDON_MS = 8_000 # a JS error within this of the session end = abandonment
      MAX_SESSIONS = 500 # display cap on returned rows (does NOT set was_truncated)
      DISTRIBUTION_BINS = %w[0-20 20-40 40-60 60-80 80-100].freeze

      ERROR_TAG = "error"
      NAVIGATION_TAG = "navigation"

      # Integer division pins boundaries: 19→"0-20", 20→"20-40", 100→"80-100".
      def self.bin_for(score)
        DISTRIBUTION_BINS[[(score / 20), 4].min]
      end

      # The MAX_SESSIONS row cap is a DISPLAY bound (keeps highest scores, does
      # NOT set was_truncated); only the scan cap sets was_truncated.
      def analyze(limit: nil, since: nil, until_time: nil)
        accumulators = {}

        scanned, hit_cap = scan_sessions(limit: limit, since: since, until_time: until_time) do |summary, window_id, events|
          session_id = summary[:session_id]
          acc = (accumulators[session_id] ||= new_accumulator(summary, window_id))
          accumulate_window(acc, events)
        end

        rows = accumulators.values.map { |acc| score_session(acc) }
        distribution = build_distribution(rows)
        rows.sort_by! { |row| [-row[:score], row[:session_id]] }

        {
          sessions: rows.first(MAX_SESSIONS),
          distribution: distribution,
          scanned: scanned,
          was_truncated: hit_cap
        }
      end

      private

      def new_accumulator(summary, window_id)
        {
          session_id: summary[:session_id],
          window_id: window_id,
          entry_url: nil,
          entry_anchor: nil,
          first_ts: nil,
          last_ts: nil,
          rage_count: 0,
          dead_count: 0,
          idle_gap_sum: 0,
          reversals: 0,
          visits: [],
          input_counts: Hash.new(0),
          distinct_urls: {},
          error_timestamps: []
        }
      end

      def accumulate_window(acc, events)
        sorted = events.sort_by { |event| event["timestamp"].is_a?(Numeric) ? event["timestamp"] : -Float::INFINITY }

        track_bounds(acc, sorted)
        track_entry_url(acc, events)

        frustration = FrustrationAnalyzer.detect_frustration_events(events)
        acc[:rage_count] += frustration.count { |entry| entry[:subtype] == "rage_click" }
        # RAW detector output (pre-refinement); may exceed the de-noised per-URL
        # counts on the frustration page — the composite score wants raw friction.
        acc[:dead_count] += frustration.count { |entry| entry[:subtype] == "dead_click" }

        acc[:idle_gap_sum] += idle_gap_sum(sorted)
        acc[:reversals] += scroll_reversals(sorted)
        collect_visits(acc, events)
        tally_inputs(acc, events)
        tally_distinct_urls(acc, events)
        collect_errors(acc, events)
      end

      def track_bounds(acc, sorted)
        numeric = sorted.filter_map { |event| event["timestamp"] if event["timestamp"].is_a?(Numeric) }
        return if numeric.empty?

        first = numeric.first
        last = numeric.last
        acc[:first_ts] = first if acc[:first_ts].nil? || first < acc[:first_ts]
        acc[:last_ts] = last if acc[:last_ts].nil? || last > acc[:last_ts]
      end

      # Earliest-timestamp Meta href across windows (yielded in no promised
      # order) — scans every Meta in every window, unlike
      # EntryAttribution#update_entry_candidate which only looks at each
      # window's first Meta. nil_anchor_is_earlier: true because the first
      # Meta accepted here can carry a nil anchor (a missing/non-numeric
      # timestamp on that event) that a later, properly-timed Meta must still
      # be able to displace.
      def track_entry_url(acc, events)
        events.each do |event|
          href = meta_href(event)
          next unless href

          anchor = event["timestamp"]
          next unless acc[:entry_url].nil? || earlier?(anchor, acc[:entry_anchor], nil_anchor_is_earlier: true)

          acc[:entry_url] = href
          acc[:entry_anchor] = anchor
        end
      end

      def idle_gap_sum(sorted)
        sum = 0
        prev = nil
        sorted.each do |event|
          ts = event["timestamp"]
          next unless ts.is_a?(Numeric)
          if prev
            gap = ts - prev
            sum += gap if gap > IDLE_GAP_MS
          end
          prev = ts
        end
        sum
      end

      # Reversal: Δy sign flips, both deltas > THRASH_MIN_DELTA_PX, within THRASH_WINDOW_MS.
      def scroll_reversals(sorted)
        scrolls = sorted.filter_map { |event| scroll_point(event) }
        return 0 if scrolls.size < 3

        reversals = 0
        prev_delta = nil
        prev_ts = nil
        (1...scrolls.size).each do |i|
          cur_ts, cur_y = scrolls[i]
          _, prev_y = scrolls[i - 1]
          delta = cur_y - prev_y

          if prev_delta &&
              (prev_delta.positive? != delta.positive?) &&
              prev_delta.abs > THRASH_MIN_DELTA_PX &&
              delta.abs > THRASH_MIN_DELTA_PX &&
              (cur_ts - prev_ts) <= THRASH_WINDOW_MS
            reversals += 1
          end

          prev_delta = delta
          prev_ts = cur_ts
        end
        reversals
      end

      def scroll_point(event)
        return nil unless event["type"] == INCREMENTAL
        data = event["data"]
        return nil unless data.is_a?(Hash) && data["source"] == SOURCE_SCROLL
        y = data["y"]
        ts = event["timestamp"]
        (y.is_a?(Numeric) && ts.is_a?(Numeric)) ? [ts, y] : nil
      end

      def collect_visits(acc, events)
        events.each do |event|
          ts = event["timestamp"]
          next unless ts.is_a?(Numeric)

          href = meta_href(event)
          if href
            acc[:visits] << [ts, href]
            next
          end

          url = navigation_url(event)
          acc[:visits] << [ts, url] if url
        end
      end

      def navigation_url(event)
        return nil unless event["type"] == CUSTOM
        data = event["data"]
        return nil unless data.is_a?(Hash) && data["tag"] == NAVIGATION_TAG
        url = data.dig("payload", "url")
        (url.is_a?(String) && !url.empty?) ? url : nil
      end

      # Masking + input:"last" make text-shrink undetectable, so a re-fill is
      # proxied as a node touched more than once.
      def tally_inputs(acc, events)
        events.each do |event|
          next unless event["type"] == INCREMENTAL
          data = event["data"]
          next unless data.is_a?(Hash) && data["source"] == SOURCE_INPUT

          id = data["id"]
          acc[:input_counts][id] += 1 if id.is_a?(Integer)
        end
      end

      def tally_distinct_urls(acc, events)
        events.each do |event|
          href = meta_href(event)
          acc[:distinct_urls][href] = true if href
        end
      end

      def collect_errors(acc, events)
        events.each do |event|
          next unless event["type"] == CUSTOM
          data = event["data"]
          next unless data.is_a?(Hash) && data["tag"] == ERROR_TAG

          ts = event["timestamp"]
          acc[:error_timestamps] << ts if ts.is_a?(Numeric)
        end
      end

      def score_session(acc)
        duration = session_duration(acc)
        signals = {
          rage_clicks: acc[:rage_count],
          dead_clicks: acc[:dead_count],
          nav_churn: nav_churn_revisits(acc),
          idle_ratio: idle_ratio(acc, duration),
          thrashing_scroll: acc[:reversals],
          quick_bounce: quick_bounce?(acc, duration),
          form_refills: form_refills(acc),
          error_abandonment: error_abandonment?(acc)
        }

        score = (WEIGHTS.sum { |key, weight| weight * sub_score(key, signals[key]) } * 100).round.clamp(0, 100)

        {
          session_id: acc[:session_id],
          window_id: acc[:window_id],
          score: score,
          url: acc[:entry_url],
          duration_ms: duration.to_i,
          signals: signals
        }
      end

      def sub_score(key, value)
        case key
        when :rage_clicks then [value / RAGE_SATURATION.to_f, 1.0].min
        when :dead_clicks then [value / DEAD_SATURATION.to_f, 1.0].min
        when :nav_churn then [value / NAV_CHURN_SATURATION.to_f, 1.0].min
        when :thrashing_scroll then [value / THRASH_SATURATION.to_f, 1.0].min
        when :form_refills then [value / REFILL_SATURATION.to_f, 1.0].min
        when :idle_ratio then value
        when :quick_bounce, :error_abandonment then value ? 1.0 : 0.0
        end
      end

      def session_duration(acc)
        return 0 unless acc[:first_ts] && acc[:last_ts]
        acc[:last_ts] - acc[:first_ts]
      end

      def nav_churn_revisits(acc)
        seen = {}
        revisits = 0
        acc[:visits].sort_by { |ts, _url| ts }.each do |_ts, url|
          if seen[url]
            revisits += 1
          else
            seen[url] = true
          end
        end
        revisits
      end

      def idle_ratio(acc, duration)
        return 0.0 unless duration && duration > 0
        [acc[:idle_gap_sum].to_f / duration, 1.0].min
      end

      # Single distinct page (zero Metas counts as one) left within QUICK_BOUNCE_MS.
      def quick_bounce?(acc, duration)
        distinct = acc[:distinct_urls].empty? ? 1 : acc[:distinct_urls].size
        distinct == 1 && duration < QUICK_BOUNCE_MS
      end

      def form_refills(acc)
        acc[:input_counts].sum { |_id, count| [count - 1, 0].max }
      end

      def error_abandonment?(acc)
        last = acc[:last_ts]
        return false unless last
        acc[:error_timestamps].any? { |ts| ts >= last - ERROR_ABANDON_MS }
      end

      # Over ALL scored sessions — built before the MAX_SESSIONS row cap.
      def build_distribution(rows)
        bins = DISTRIBUTION_BINS.to_h { |label| [label, 0] }
        rows.each { |row| bins[self.class.bin_for(row[:score])] += 1 }
        bins
      end
    end
  end
end
