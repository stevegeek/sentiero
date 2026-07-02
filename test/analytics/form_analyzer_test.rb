# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/form_analyzer"

module Sentiero
  module Analytics
    class FormAnalyzerTest < Minitest::Test
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

      # An rrweb input event: incremental (type 3) of source Input (5), carrying
      # the touched node's id. Values are never read (works with maskAllInputs).
      def input_event(node_id, offset)
        {"type" => 3, "timestamp" => now_ms + offset, "data" => {"source" => 5, "id" => node_id, "text" => "*", "isChecked" => false}}
      end

      # A real submit: the recorder's capture-phase submit listener emits a
      # __form_submit custom event with the form's non-PII identity + page url.
      def submit_event(offset, name: nil, url: nil)
        payload = {}
        payload["name"] = name if name
        payload["url"] = url if url
        {"type" => 5, "timestamp" => now_ms + offset, "data" => {"tag" => "__form_submit", "payload" => payload}}
      end

      # A Meta (navigation) event. Under the old heuristic this counted as a
      # submit; it must NOT any more.
      def meta_event(href, offset)
        {"type" => 4, "timestamp" => now_ms + offset, "data" => {"href" => href, "width" => 1280, "height" => 800}}
      end

      def seed(session_id, events, window_id: "w1")
        @store.save_events(Sentiero::WindowRef.new(session_id, window_id), events)
      end

      # An rrweb full snapshot (type 2) wrapping a small DOM tree of form
      # controls, so the analyzer can resolve node ids to human labels. Each
      # control is {id:, tag:, attrs:}.
      def snapshot_event(offset, controls)
        children = controls.map do |c|
          {"type" => 2, "tagName" => c[:tag] || "input", "id" => c[:id], "attributes" => c[:attrs] || {}, "childNodes" => []}
        end
        body = {"type" => 2, "tagName" => "body", "id" => 1, "attributes" => {}, "childNodes" => children}
        {"type" => 2, "timestamp" => now_ms + offset, "data" => {"node" => body}}
      end

      def analyze(**opts)
        FormAnalyzer.new(@store).analyze(**opts)
      end

      # ── extraction ──

      def test_empty_store_returns_empty_results
        result = analyze

        assert_equal 0, result[:sessions_with_form_interaction]
        assert_equal 0, result[:sessions_completed]
        assert_equal 0, result[:total_submits]
        assert_empty result[:fields]
        refute result[:was_truncated]
      end

      # ── B3: human field labels from the DOM snapshot ──

      def test_fields_labelled_from_snapshot_name_id_type
        seed("s1", [
          snapshot_event(0, [
            {id: 65, tag: "input", attrs: {"name" => "email", "id" => "signup-email", "type" => "email"}},
            {id: 84, tag: "select", attrs: {"name" => "plan", "id" => "signup-plan"}},
            {id: 92, tag: "input", attrs: {"type" => "password"}}
          ]),
          input_event(65, 100), submit_event(200)
        ])
        labels = analyze[:fields].map { |f| f[:label] }
        # name wins, with input type for context
        assert_includes labels, "email (email)"
      end

      def test_same_node_id_labelled_per_page_not_conflated
        # The ground-truth conflation: node id 65 is "name" on /signup but
        # "text" on /app. Per-(url,id) keying + per-segment snapshots keep them
        # separate AND distinctly labelled.
        seed("s1", [
          meta_event("https://ex.com/signup", 0),
          snapshot_event(1, [{id: 65, attrs: {"name" => "name", "type" => "text"}}]),
          input_event(65, 10),
          meta_event("https://ex.com/app", 100),
          snapshot_event(101, [{id: 65, attrs: {"name" => "todo", "type" => "text"}}]),
          input_event(65, 110)
        ])
        by_url = analyze[:fields].to_h { |f| [f[:url], f[:label]] }
        assert_equal "name (text)", by_url["https://ex.com/signup"]
        assert_equal "todo (text)", by_url["https://ex.com/app"]
      end

      def test_field_without_snapshot_has_nil_label_for_fallback
        seed("s1", [input_event(10, 0), submit_event(5)])
        assert_nil analyze[:fields].first[:label]
      end

      def test_ignores_non_input_events
        seed("s1", [
          {"type" => 3, "timestamp" => now_ms, "data" => {"source" => 2, "type" => 2, "id" => 9, "x" => 1, "y" => 1}},
          {"type" => 4, "timestamp" => now_ms + 1, "data" => {"height" => 800}}
        ])

        assert_empty analyze[:fields]
        assert_equal 0, analyze[:sessions_with_form_interaction]
      end

      def test_groups_input_events_by_node_id
        seed("s1", [input_event(10, 0), input_event(11, 5), input_event(10, 10)])

        fields = analyze[:fields]

        assert_equal 2, fields.size
        assert(fields.any? { |f| f[:field_id] == 10 })
        assert(fields.any? { |f| f[:field_id] == 11 })
      end

      # ── time-to-fill ──

      def test_time_to_fill_is_last_minus_first_input_per_field
        seed("s1", [input_event(10, 100), input_event(10, 400), submit_event(500)])

        field = analyze[:fields].find { |f| f[:field_id] == 10 }

        assert_in_delta 300.0, field[:avg_time_to_fill_ms], 0.01
      end

      def test_time_to_fill_averages_across_sessions
        seed("s1", [input_event(10, 0), input_event(10, 200), submit_event(300)])
        seed("s2", [input_event(10, 0), input_event(10, 600), submit_event(700)])

        field = analyze[:fields].find { |f| f[:field_id] == 10 }

        assert_in_delta 400.0, field[:avg_time_to_fill_ms], 0.01
      end

      # ── re-fill frequency ──

      def test_refill_count_is_input_events_minus_one_per_field
        seed("s1", [input_event(10, 0), input_event(10, 5), input_event(10, 9), submit_event(20)])

        field = analyze[:fields].find { |f| f[:field_id] == 10 }

        assert_equal 2, field[:total_refills]
      end

      def test_single_input_has_no_refill
        seed("s1", [input_event(10, 0), submit_event(5)])

        field = analyze[:fields].find { |f| f[:field_id] == 10 }

        assert_equal 0, field[:total_refills]
      end

      # ── completion / submits ──

      def test_completion_rate_counts_started_vs_submitted
        seed("completed", [input_event(10, 0), submit_event(10)])
        seed("abandoned", [input_event(10, 0)])

        result = analyze

        assert_equal 2, result[:sessions_with_form_interaction]
        assert_equal 1, result[:sessions_completed]
        assert_in_delta 0.5, result[:completion_rate], 0.01
      end

      # The P1.4 fix: a bare navigation (Meta) after the last input is no
      # longer a submit. Windows recorded by recorders predating the
      # __form_submit capture (or with track_forms off) carry no submit
      # events and must gracefully report ZERO submits — never fall back to
      # Meta counting.
      def test_meta_navigation_no_longer_counts_as_submit
        seed("legacy", [
          meta_event("https://x.test/signup", 0),
          input_event(10, 10),
          input_event(11, 20),
          meta_event("https://x.test/done", 100)
        ])

        result = analyze

        assert_equal 1, result[:sessions_with_form_interaction]
        assert_equal 0, result[:sessions_completed]
        assert_equal 0, result[:total_submits]
        assert_in_delta 0.0, result[:completion_rate], 0.01
      end

      def test_total_submits_counts_every_form_submit_event
        # Submits count even on pages without tracked inputs (e.g. a one-click
        # toggle form).
        seed("s1", [input_event(10, 0), submit_event(10), submit_event(50)])
        seed("s2", [submit_event(0)])

        assert_equal 3, analyze[:total_submits]
      end

      def test_submit_before_first_input_does_not_complete_the_page
        seed("s1", [submit_event(0), input_event(10, 10)])

        result = analyze

        assert_equal 1, result[:sessions_with_form_interaction]
        assert_equal 0, result[:sessions_completed]
        assert_equal 1, result[:total_submits]
      end

      def test_completion_rate_zero_when_no_interaction
        assert_equal 0, analyze[:completion_rate]
      end

      # ── per-page segmentation (rides Analyzer#each_page_segment) ──

      # The ground-truth S1 shape: / → /signup (3 fields + submit) → /app
      # (todo form: input + submit per full-page POST reload, same href).
      # One window, one session — every page unit submitted.
      def seed_converter(session_id)
        seed(session_id, [
          meta_event("https://x.test/", 0),
          meta_event("https://x.test/signup", 100),
          input_event(30, 110), # name field (node ids reset per page load,
          input_event(31, 120), # so /signup and /app can both have id 30)
          input_event(32, 130), # plan radio
          submit_event(140, name: "signup", url: "https://x.test/signup"),
          meta_event("https://x.test/app", 200),
          input_event(30, 210),
          submit_event(220, url: "https://x.test/app"),
          meta_event("https://x.test/app", 230),
          input_event(30, 240),
          submit_event(250, url: "https://x.test/app"),
          meta_event("https://x.test/app", 260),
          input_event(30, 270),
          submit_event(280, url: "https://x.test/app")
        ])
      end

      # The ground-truth S3 shape: touches the plan field on /signup but never
      # submits there, then adds a todo on /app (a genuine submit). The /app
      # submit must NOT mask the /signup abandonment.
      def seed_abandoner(session_id)
        seed(session_id, [
          meta_event("https://x.test/", 0),
          meta_event("https://x.test/signup", 100),
          input_event(32, 110), # plan radio, then leaves via the nav link
          meta_event("https://x.test/app", 200),
          input_event(30, 210),
          submit_event(220, url: "https://x.test/app")
        ])
      end

      def test_ground_truth_converter_and_abandoner
        seed_converter("s1")
        seed_abandoner("s3")

        result = analyze

        # S1: signup submit + 3 todo submits; S3: 1 todo submit.
        assert_equal 5, result[:total_submits]
        assert_equal 2, result[:sessions_with_form_interaction]
        # S3 abandoned /signup, so it is NOT completed despite its todo submit.
        assert_equal 1, result[:sessions_completed]
        assert_in_delta 0.5, result[:completion_rate], 0.01

        drop_off = result[:drop_off_fields]
        assert_equal 1, drop_off.size
        assert_equal 32, drop_off.first[:field_id]
        assert_equal "https://x.test/signup", drop_off.first[:url]
        assert_equal 1, drop_off.first[:count]
      end

      def test_fields_are_keyed_per_page_not_just_node_id
        # Node id 30 exists on BOTH /signup (name field) and /app (todo input);
        # they must be separate rows, not one conflated "Field #30".
        seed_converter("s1")

        rows = analyze[:fields].select { |f| f[:field_id] == 30 }

        assert_equal 2, rows.size
        assert_equal ["https://x.test/app", "https://x.test/signup"], rows.map { |f| f[:url] }.sort
      end

      def test_same_href_reloads_form_one_segment
        # Full-page form POSTs reload the same URL; the todo field's three
        # touches stay ONE field row with one session.
        seed_converter("s1")

        todo = analyze[:fields].find { |f| f[:field_id] == 30 && f[:url] == "https://x.test/app" }

        assert_equal 1, todo[:sessions]
      end

      def test_submit_on_a_later_page_does_not_complete_an_earlier_page
        seed("s1", [
          meta_event("https://x.test/signup", 0),
          input_event(10, 10),
          meta_event("https://x.test/other", 100),
          submit_event(110, url: "https://x.test/other")
        ])

        result = analyze

        assert_equal 0, result[:sessions_completed]
        assert_equal 1, result[:total_submits]
        assert_equal "https://x.test/signup", result[:drop_off_fields].first[:url]
      end

      # ── per-field completion rate ──

      def test_field_completion_rate_is_sessions_touched_over_started
        seed("s1", [input_event(10, 0), input_event(11, 5), submit_event(10)])
        seed("s2", [input_event(10, 0), submit_event(5)])

        fields = analyze[:fields]
        field10 = fields.find { |f| f[:field_id] == 10 }
        field11 = fields.find { |f| f[:field_id] == 11 }

        # Field 10 touched in both sessions; field 11 only in one.
        assert_in_delta 1.0, field10[:completion_rate], 0.01
        assert_in_delta 0.5, field11[:completion_rate], 0.01
      end

      # ── drop-off ──

      def test_drop_off_is_last_field_in_abandoned_session
        seed("abandoned", [input_event(10, 0), input_event(11, 5)])

        drop_off = analyze[:drop_off_fields]

        assert_equal 1, drop_off.size
        assert_equal 11, drop_off.first[:field_id]
        assert_equal 1, drop_off.first[:count]
      end

      def test_completed_session_does_not_contribute_drop_off
        seed("completed", [input_event(10, 0), input_event(11, 5), submit_event(10)])

        assert_empty analyze[:drop_off_fields]
      end

      def test_drop_off_aggregates_across_sessions
        seed("a1", [input_event(10, 0), input_event(11, 5)])
        seed("a2", [input_event(10, 0), input_event(11, 5)])
        seed("a3", [input_event(10, 0)])

        drop_off = analyze[:drop_off_fields]
        field10 = drop_off.find { |f| f[:field_id] == 10 }
        field11 = drop_off.find { |f| f[:field_id] == 11 }

        assert_equal 2, field11[:count]
        assert_equal 1, field10[:count]
      end

      # ── privacy ──

      def test_does_not_leak_input_values
        seed("s1", [
          {"type" => 3, "timestamp" => now_ms, "data" => {"source" => 5, "id" => 10, "text" => "secret@example.com"}},
          submit_event(5)
        ])

        refute_includes analyze.inspect, "secret@example.com"
      end

      # ── multi-window sessions ──

      # each_session_events yields once per window; a session opened in two
      # windows must still count as one started/completed and one per-field touch.
      def test_multi_window_session_counted_once
        seed("s1", [input_event(10, 0)], window_id: "w1")
        seed("s1", [input_event(11, 5)], window_id: "w2")

        result = analyze

        assert_equal 1, result[:sessions_with_form_interaction]
        assert_equal 0, result[:sessions_completed]
        assert_equal 2, result[:fields].size
        result[:fields].each { |field| assert_in_delta 1.0, field[:completion_rate], 0.01 }
      end

      def test_multi_window_session_merges_completion
        seed("s1", [input_event(10, 0)], window_id: "w1")
        seed("s1", [input_event(11, 5), submit_event(10)], window_id: "w2")

        result = analyze

        assert_equal 1, result[:sessions_with_form_interaction]
        assert_equal 1, result[:sessions_completed]
        assert_in_delta 1.0, result[:completion_rate], 0.01
        assert_empty result[:drop_off_fields]
      end

      # ── scan cap ──

      def test_respects_scan_cap
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 1)
        seed("s1", [input_event(10, 0), submit_event(5)])
        seed("s2", [input_event(11, 0), submit_event(5)])

        result = analyze

        assert_equal 1, result[:sessions_with_form_interaction]
        assert result[:was_truncated]
      end

      def test_explicit_limit_overrides_config
        seed("s1", [input_event(10, 0), submit_event(5)])
        seed("s2", [input_event(11, 0), submit_event(5)])

        result = analyze(limit: 1)

        assert_equal 1, result[:sessions_with_form_interaction]
        assert result[:was_truncated]
      end

      def test_not_truncated_when_under_cap
        seed("s1", [input_event(10, 0), submit_event(5)])

        refute analyze[:was_truncated]
      end

      # ── since/until_time bounds ──

      def test_analyze_honors_date_bounds
        seed("s1", [input_event(10, 0), submit_event(100)])

        out_of_window = analyze(until_time: Time.now.to_f - 3600)
        in_window = analyze(since: Time.now.to_f - 3600, until_time: Time.now.to_f + 3600)

        assert_equal 0, out_of_window[:sessions_with_form_interaction]
        assert_equal 1, in_window[:sessions_with_form_interaction]
      end
    end
  end
end
