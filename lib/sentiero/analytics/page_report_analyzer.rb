# frozen_string_literal: true

require_relative "analyzer"
require_relative "frustration_analyzer"
require_relative "collectors/click_collector"
require_relative "collectors/scroll_collector"
require_relative "collectors/vitals_collector"
require_relative "collectors/error_collector"
require_relative "collectors/custom_tag_collector"
require_relative "collectors/form_collector"
require_relative "collectors/frustration_collector"

module Sentiero
  module Analytics
    # Per-URL drill-down: composes the suite's metrics (heatmap, scroll, forms,
    # vitals, frustration, errors, custom tags) for one URL into one report via
    # ONE bounded Store#each_session_events scan. Per-segment math lives in
    # shared Collectors::. Frustration is the exception: only detection is shared
    # (FrustrationAnalyzer.detect_frustration_events); the cross-session
    # aggregation differs, so this URL's attribution uses FrustrationCollector.
    class PageReportAnalyzer < Analyzer
      # Output bounds — each caps a collector (flips #capped on hit).
      MAX_SELECTORS = 200
      MAX_SAMPLES_PER_METRIC = 2000
      MAX_ERROR_GROUPS = 200
      MAX_ERROR_OCCURRENCES = 50
      MAX_CUSTOM_TAGS = 200
      MAX_FIELDS = 500

      # Display limits.
      TOP_ELEMENTS_LIMIT = 20
      TOP_SELECTORS_LIMIT = 10

      # since/until_time are epoch seconds. Every result key is always present.
      def analyze(target_url, limit: nil, since: nil, until_time: nil)
        acc = new_accumulator

        _scanned, hit_cap = scan_sessions(limit: limit, since: since, until_time: until_time) do |summary, window_id, events|
          session_id = summary[:session_id]

          # Detect over the FULL window: frustration semantics span page
          # boundaries. FrustrationCollector then attributes each incident to a
          # segment by object identity.
          frustration = FrustrationAnalyzer.detect_frustration_events(events)

          segment_index = 0
          last_index = nil
          first_was_target = false
          target_segments = 0

          each_page_segment(events) do |url, segment, anchor|
            matches = url == target_url
            first_was_target = true if segment_index.zero? && matches
            last_index = segment_index if matches
            segment_index += 1

            next unless matches

            target_segments += 1
            acc[:page_views] += 1
            acc[:sessions][session_id] = true

            collect_time_on_page(acc, segment)
            collect_heatmap(acc, segment, session_id, window_id)
            acc[:vitals].collect(segment, session_id: session_id, window_id: window_id, anchor: anchor)
            acc[:errors].collect(segment, session_id: session_id, window_id: window_id, anchor: anchor)
            acc[:custom_tags].collect(segment)
            acc[:forms].collect(session_id, url, segment)
            acc[:scroll].observe(target_url, segment)
            acc[:frustration].collect(frustration, segment)
          end

          # entry/exit/bounce decided once per window from the segment order.
          if target_segments.positive?
            acc[:windows_on_page] += 1
            acc[:entries] += 1 if first_was_target
            acc[:exits] += 1 if last_index == segment_index - 1
            acc[:bounces] += 1 if segment_index == 1 && first_was_target
          end

          # One scroll sample per (session, window): deepest wins.
          acc[:scroll].flush_window
        end

        build_result(target_url, acc, hit_cap)
      end

      private

      def new_accumulator
        {
          page_views: 0,
          sessions: {},
          dwell_samples: [],
          windows_on_page: 0,
          entries: 0,
          exits: 0,
          bounces: 0,
          representative: nil,
          clicks: ClickCollector.new(max_selectors: MAX_SELECTORS),
          scroll: ScrollCollector.new,
          vitals: VitalsCollector.new(max_samples: MAX_SAMPLES_PER_METRIC),
          errors: ErrorCollector.new(max_groups: MAX_ERROR_GROUPS, max_occurrences: MAX_ERROR_OCCURRENCES),
          custom_tags: CustomTagCollector.new(max_tags: MAX_CUSTOM_TAGS),
          forms: FormCollector.new(max_fields: MAX_FIELDS),
          frustration: FrustrationCollector.new(max_selectors: MAX_SELECTORS)
        }
      end

      # An A→B→A revisit yields TWO target segments, hence TWO dwell samples —
      # intended ("time on page per visit").
      def collect_time_on_page(acc, segment)
        timestamps = segment.filter_map { |e| e["timestamp"] if e["timestamp"].is_a?(Numeric) }
        return if timestamps.size < 2
        acc[:dwell_samples] << (timestamps.max - timestamps.min)
      end

      # A segment with no valid Meta width/height contributes zero clicks
      # (collect returns nil) and never becomes the representative window.
      def collect_heatmap(acc, segment, session_id, window_id)
        added = acc[:clicks].collect(segment)
        acc[:representative] ||= {session_id: session_id, window_id: window_id} unless added.nil?
      end

      def build_result(target_url, acc, hit_cap)
        collectors = [acc[:clicks], acc[:scroll], acc[:vitals], acc[:errors], acc[:custom_tags], acc[:forms], acc[:frustration]]
        {
          url: target_url,
          sessions: acc[:sessions].size,
          page_views: acc[:page_views],
          time_on_page: summarize_time_on_page(acc[:dwell_samples]),
          entry_exit: {
            entries: acc[:entries],
            exits: acc[:exits],
            bounce_rate: acc[:entries].zero? ? 0.0 : acc[:bounces].to_f / acc[:entries],
            windows_on_page: acc[:windows_on_page]
          },
          heatmap: {
            top_elements: top_selectors(acc[:clicks].selectors, TOP_ELEMENTS_LIMIT),
            total_clicks: acc[:clicks].total,
            representative_window: acc[:representative]
          },
          scroll: acc[:scroll].summarize(target_url),
          forms: build_forms_section(acc[:forms]),
          vitals: build_vitals_section(acc[:vitals]),
          errors: acc[:errors].summarize,
          frustration: {
            rage_count: acc[:frustration].rage_count,
            dead_count: acc[:frustration].dead_count,
            top_selectors: top_selectors(acc[:frustration].selectors, TOP_SELECTORS_LIMIT)
          },
          custom_events: acc[:custom_tags].top(MAX_CUSTOM_TAGS),
          was_truncated: collectors.any?(&:capped) || hit_cap
        }
      end

      def summarize_time_on_page(samples)
        return {mean_ms: nil, median_ms: nil, samples: 0} if samples.empty?

        sorted = samples.sort
        {
          mean_ms: (samples.sum.to_f / samples.size).round,
          median_ms: percentile(sorted, 50),
          samples: samples.size
        }
      end

      def build_forms_section(forms)
        started = forms.started_count
        {
          started: started,
          # "completed" here = session submitted on the target URL at all
          # (submitted_count), not FormAnalyzer's stricter completed_count.
          completed: forms.submitted_count,
          completion_rate: started.zero? ? 0.0 : forms.submitted_count.to_f / started,
          total_submits: forms.total_submits,
          fields: forms.summarize_fields(started),
          drop_off_fields: forms.summarize_drop_off
        }
      end

      # The collector's worst-sample carries :value (WebVitalsAnalyzer needs it);
      # the page report exposes only the replay-link coordinates.
      def build_vitals_section(vitals)
        result = vitals.summarize
        result[:metrics].each_value do |metric|
          metric[:worst] = metric[:worst]&.slice(:session_id, :window_id, :offset_ms)
        end
        result
      end

      def top_selectors(selectors, limit)
        top_counts(selectors, limit: limit)
          .map { |selector, count| {selector: selector, count: count} }
      end
    end
  end
end
