# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/collectors/form_collector"

module Sentiero
  module Analytics
    # Unit-level guarantees for the per-segment form math shared by
    # FormAnalyzer and PageReportAnalyzer. A "segment" is the array of rrweb
    # event hashes Analyzer#each_page_segment yields.
    class FormCollectorTest < Minitest::Test
      URL = "https://example.com/signup"
      SID = "session-1"

      # rrweb input event: incremental (type 3) of source Input (5).
      def input(node_id, ts: 1)
        {"type" => 3, "timestamp" => ts, "data" => {"source" => 5, "id" => node_id}}
      end

      # __form_submit custom event.
      def submit(ts: 10)
        {"type" => 5, "timestamp" => ts, "data" => {"tag" => "__form_submit", "payload" => {}}}
      end

      # ── basic collect behaviour ──────────────────────────────────────────────

      def test_collect_empty_segment_returns_zero_and_changes_nothing
        c = FormCollector.new
        assert_equal 0, c.collect(SID, URL, [])
        assert_equal 0, c.started_count
        assert_equal 0, c.total_submits
        assert_empty c.summarize_fields(0)
      end

      def test_collect_segment_with_only_submit_increments_total_submits_and_submitted_count
        c = FormCollector.new
        c.collect(SID, URL, [submit])
        assert_equal 1, c.total_submits
        assert_equal 0, c.started_count
        assert_equal 1, c.submitted_count  # session had a submit
        assert_equal 0, c.completed_count  # but never started — no inputs
      end

      def test_collect_returns_input_count
        c = FormCollector.new
        assert_equal 2, c.collect(SID, URL, [input(10), input(11), submit])
      end

      # ── started / submitted / completed semantics ────────────────────────────

      def test_segment_with_inputs_and_submit_marks_started_and_completed
        c = FormCollector.new
        c.collect(SID, URL, [input(10), submit])
        assert_equal 1, c.started_count
        assert_equal 1, c.completed_count  # FormAnalyzer: no abandoned segment
        assert_equal 1, c.submitted_count  # PageReport: had a submit
      end

      def test_segment_with_inputs_but_no_submit_is_abandoned
        c = FormCollector.new
        c.collect(SID, URL, [input(10)])
        assert_equal 1, c.started_count
        assert_equal 0, c.completed_count  # FormAnalyzer: abandoned
        assert_equal 0, c.submitted_count  # PageReport: no submit
      end

      def test_submit_before_first_input_does_not_complete_the_segment
        # A __form_submit that precedes the first input belongs to a prior
        # interaction — this segment's inputs are still abandoned.
        c = FormCollector.new
        c.collect(SID, URL, [submit(ts: 1), input(10, ts: 10)])
        assert_equal 1, c.started_count
        assert_equal 0, c.completed_count  # submit before input → abandoned
        assert_equal 1, c.submitted_count  # raw submit still registered
      end

      def test_multiple_segments_same_session_all_submitted_is_completed
        c = FormCollector.new
        c.collect(SID, URL, [input(10, ts: 1), submit(ts: 5)])
        c.collect(SID, "https://example.com/other", [input(20, ts: 10), submit(ts: 15)])
        assert_equal 1, c.started_count
        assert_equal 1, c.completed_count
      end

      def test_multiple_segments_same_session_one_abandoned_is_not_completed
        c = FormCollector.new
        c.collect(SID, URL, [input(10, ts: 1), submit(ts: 5)])
        c.collect(SID, "https://example.com/other", [input(20, ts: 10)])  # abandoned
        assert_equal 1, c.started_count
        assert_equal 0, c.completed_count  # any abandoned segment → not completed
        assert_equal 1, c.submitted_count  # still had a submit somewhere
      end

      def test_multiple_sessions_counted_independently
        c = FormCollector.new
        c.collect("s1", URL, [input(10), submit])
        c.collect("s2", URL, [input(10)])
        assert_equal 2, c.started_count
        assert_equal 1, c.completed_count
        assert_equal 1, c.submitted_count
      end

      # ── total_submits is a raw event count ───────────────────────────────────

      def test_total_submits_is_raw_count_not_session_count
        c = FormCollector.new
        c.collect("s1", URL, [input(10), submit, submit])  # two submits, one session
        c.collect("s2", URL, [submit])                      # one submit, no inputs
        assert_equal 3, c.total_submits
      end

      # ── field accumulation ───────────────────────────────────────────────────

      def test_fields_keyed_per_url_and_node_id
        c = FormCollector.new
        # Same node_id on two different URLs → two distinct field rows.
        c.collect("s1", URL, [input(10), submit])
        c.collect("s1", "https://example.com/other", [input(10), submit])
        assert_equal 2, c.summarize_fields(1).size
      end

      def test_field_session_deduped_for_same_session
        c = FormCollector.new
        c.collect("s1", URL, [input(10, ts: 1), input(10, ts: 5), submit])
        c.collect("s1", URL, [input(10, ts: 10), submit])  # same session, same URL
        assert_equal 1, c.summarize_fields(c.started_count).first[:sessions]
      end

      def test_field_sessions_counts_across_distinct_sessions
        c = FormCollector.new
        c.collect("s1", URL, [input(10), submit])
        c.collect("s2", URL, [input(10), submit])
        assert_equal 2, c.summarize_fields(c.started_count).first[:sessions]
      end

      def test_time_to_fill_is_max_minus_min_timestamp_per_field
        c = FormCollector.new
        c.collect(SID, URL, [input(10, ts: 100), input(10, ts: 400), submit(ts: 500)])
        field = c.summarize_fields(1).first
        assert_in_delta 300.0, field[:avg_time_to_fill_ms], 0.01
      end

      def test_refills_are_input_events_minus_one
        c = FormCollector.new
        c.collect(SID, URL, [input(10, ts: 1), input(10, ts: 2), input(10, ts: 3), submit])
        assert_equal 2, c.summarize_fields(1).first[:total_refills]
      end

      def test_single_input_has_zero_refills
        c = FormCollector.new
        c.collect(SID, URL, [input(10), submit])
        assert_equal 0, c.summarize_fields(1).first[:total_refills]
      end

      def test_fields_sorted_by_sessions_descending
        c = FormCollector.new
        # node 11: 2 sessions; node 10: 1 session.
        c.collect("s1", URL, [input(10), input(11), submit])
        c.collect("s2", URL, [input(11), submit])
        fields = c.summarize_fields(2)
        assert_equal 11, fields.first[:field_id]
        assert_equal 10, fields.last[:field_id]
      end

      def test_summarize_fields_completion_rate_is_field_sessions_over_started
        c = FormCollector.new
        c.collect("s1", URL, [input(10), input(11), submit])
        c.collect("s2", URL, [input(10), submit])
        fields = c.summarize_fields(2)
        field10 = fields.find { |f| f[:field_id] == 10 }
        field11 = fields.find { |f| f[:field_id] == 11 }
        assert_in_delta 1.0, field10[:completion_rate], 0.01  # 2/2
        assert_in_delta 0.5, field11[:completion_rate], 0.01  # 1/2
      end

      def test_summarize_fields_completion_rate_zero_when_started_is_zero
        c = FormCollector.new
        c.collect(SID, URL, [input(10), submit])
        assert_in_delta 0.0, c.summarize_fields(0).first[:completion_rate], 0.01
      end

      # ── labels ───────────────────────────────────────────────────────────────

      def test_label_populated_from_labels_argument
        c = FormCollector.new
        c.collect(SID, URL, [input(10), submit], labels: {10 => "email"})
        field = c.summarize_fields(1, include_labels: true).first
        assert_equal "email", field[:label]
      end

      def test_label_nil_when_not_provided
        c = FormCollector.new
        c.collect(SID, URL, [input(10), submit])
        assert_nil c.summarize_fields(1, include_labels: true).first[:label]
      end

      def test_include_labels_false_omits_label_key
        c = FormCollector.new
        c.collect(SID, URL, [input(10), submit])
        field = c.summarize_fields(1, include_labels: false).first
        refute field.key?(:label)
      end

      def test_include_labels_defaults_to_false
        c = FormCollector.new
        c.collect(SID, URL, [input(10), submit])
        refute c.summarize_fields(1).first.key?(:label)
      end

      def test_first_label_wins_across_same_segment_revisits
        c = FormCollector.new
        c.collect(SID, URL, [input(10), submit], labels: {10 => "email"})
        c.collect(SID, URL, [input(10), submit], labels: {10 => "later-label"})
        assert_equal "email", c.summarize_fields(1, include_labels: true).first[:label]
      end

      # ── drop-off ─────────────────────────────────────────────────────────────

      def test_drop_off_records_last_field_in_abandoned_segment
        c = FormCollector.new
        c.collect(SID, URL, [input(10), input(11)])  # abandoned, last field is 11
        drop_off = c.summarize_drop_off
        assert_equal 1, drop_off.size
        assert_equal 11, drop_off.first[:field_id]
        assert_equal URL, drop_off.first[:url]
        assert_equal 1, drop_off.first[:count]
      end

      def test_drop_off_not_recorded_for_submitted_segment
        c = FormCollector.new
        c.collect(SID, URL, [input(10), submit])
        assert_empty c.summarize_drop_off
      end

      def test_drop_off_aggregates_count_across_sessions
        c = FormCollector.new
        c.collect("s1", URL, [input(10), input(11)])
        c.collect("s2", URL, [input(10), input(11)])
        c.collect("s3", URL, [input(10)])
        drop_off = c.summarize_drop_off
        assert_equal 2, drop_off.find { |e| e[:field_id] == 11 }[:count]
        assert_equal 1, drop_off.find { |e| e[:field_id] == 10 }[:count]
      end

      def test_summarize_drop_off_includes_label_when_requested
        c = FormCollector.new
        c.collect(SID, URL, [input(10)], labels: {10 => "email"})
        drop_off = c.summarize_drop_off(include_labels: true)
        assert_equal "email", drop_off.first[:label]
      end

      def test_summarize_drop_off_omits_label_by_default
        c = FormCollector.new
        c.collect(SID, URL, [input(10)])
        refute c.summarize_drop_off.first.key?(:label)
      end

      def test_summarize_drop_off_omits_label_when_include_labels_false
        c = FormCollector.new
        c.collect(SID, URL, [input(10)])
        refute c.summarize_drop_off(include_labels: false).first.key?(:label)
      end

      # ── max_fields cap ───────────────────────────────────────────────────────

      def test_max_fields_caps_distinct_fields_and_flips_capped
        c = FormCollector.new(max_fields: 1)
        c.collect(SID, URL, [input(10), input(11)])
        assert_equal 1, c.summarize_fields(0).size
        assert c.capped
      end

      def test_already_seen_field_still_accumulates_after_cap
        c = FormCollector.new(max_fields: 1)
        c.collect("s1", URL, [input(10), submit])
        c.collect("s2", URL, [input(10), input(11), submit])  # 10 seen, 11 rejected
        entry = c.summarize_fields(c.started_count).find { |f| f[:field_id] == 10 }
        assert_equal 2, entry[:sessions]
        assert c.capped
      end

      def test_unbounded_collector_never_caps
        c = FormCollector.new
        300.times { |i| c.collect("s#{i}", URL, [input(i), submit]) }
        assert_equal 300, c.summarize_fields(c.started_count).size
        refute c.capped
      end
    end
  end
end
