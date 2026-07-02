# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/funnel_analyzer"

module Sentiero
  module Analytics
    class FunnelAnalyzerTest < Minitest::Test
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

      # Seeds a session window opening with an anchor event (the replay offset
      # reference) followed by one custom event per [tag, offset_ms] pair.
      def seed_session(session_id, tagged, window_id: "w1", at: now_ms)
        events = [{"type" => 3, "timestamp" => at}]
        tagged.each do |tag, offset|
          events << {"type" => 5, "timestamp" => at + offset, "data" => {"tag" => tag, "payload" => {}}}
        end
        @store.save_events(Sentiero::WindowRef.new(session_id, window_id), events)
      end

      def analyze(steps = [], **opts)
        FunnelAnalyzer.new(@store).analyze(steps, **opts)
      end

      # ── step validation ──

      def test_internal_and_blank_tags_are_rejected_from_steps
        assert_equal %w[signup checkout], FunnelAnalyzer.usable_steps(["signup", "__perf", "error", nil, "", "checkout"])
      end

      def test_steps_capped_at_max
        steps = FunnelAnalyzer.usable_steps(%w[a b c d])

        assert_equal FunnelAnalyzer::MAX_STEPS, steps.size
        assert_equal %w[a b c], steps
      end

      def test_fewer_than_two_usable_steps_yields_no_funnel
        seed_session("s1", [["signup", 100]])

        result = analyze(["signup", "__perf"])

        assert_empty result[:steps]
      end

      # ── tag vocabulary ──

      def test_vocabulary_lists_observed_tags_sorted_excluding_internal
        seed_session("s1", [["signup", 100], ["checkout", 200], ["__perf", 300], ["__click", 400], ["error", 500]])

        result = analyze

        assert_equal %w[checkout signup], result[:tags]
      end

      def test_vocabulary_cap_flags_truncation
        tagged = (FunnelAnalyzer::MAX_TAGS + 1).times.map { |i| ["tag#{i}", i + 1] }
        seed_session("s1", tagged)

        result = analyze

        assert_equal FunnelAnalyzer::MAX_TAGS, result[:tags].size
        assert result[:was_truncated]
      end

      # ── ordered step presence ──

      def test_session_with_steps_in_order_converts
        seed_session("s1", [["signup", 100], ["checkout", 200]])

        steps = analyze(%w[signup checkout])[:steps]

        assert_equal 1, steps[0][:sessions]
        assert_equal 1, steps[1][:sessions]
      end

      def test_step_two_before_step_one_does_not_count
        # checkout happens BEFORE signup: the session reaches step 1 only.
        seed_session("s1", [["checkout", 100], ["signup", 200]])

        steps = analyze(%w[signup checkout])[:steps]

        assert_equal 1, steps[0][:sessions]
        assert_equal 0, steps[1][:sessions]
      end

      def test_same_timestamp_is_not_after
        seed_session("s1", [["signup", 100], ["checkout", 100]])

        steps = analyze(%w[signup checkout])[:steps]

        assert_equal 1, steps[0][:sessions]
        assert_equal 0, steps[1][:sessions]
      end

      def test_three_step_funnel_requires_each_step_after_the_previous
        seed_session("full", [["a", 100], ["b", 200], ["c", 300]])
        # missing the middle step: reaches step 1 only
        seed_session("skips-b", [["a", 100], ["c", 300]])
        # middle step too early: b before a never chains
        seed_session("b-first", [["b", 50], ["a", 100], ["c", 300]])

        steps = analyze(%w[a b c])[:steps]

        assert_equal 3, steps[0][:sessions]
        assert_equal 1, steps[1][:sessions]
        assert_equal 1, steps[2][:sessions]
      end

      def test_duplicate_step_tags_need_strictly_later_occurrences
        seed_session("twice", [["click", 100], ["click", 200]])
        seed_session("once", [["click", 100]])

        steps = analyze(%w[click click])[:steps]

        assert_equal 2, steps[0][:sessions]
        assert_equal 1, steps[1][:sessions]
      end

      def test_steps_chain_across_windows_of_the_same_session
        seed_session("s1", [["signup", 100]], window_id: "w1", at: now_ms)
        seed_session("s1", [["checkout", 100]], window_id: "w2", at: now_ms + 10_000)

        steps = analyze(%w[signup checkout])[:steps]

        assert_equal 1, steps[0][:sessions]
        assert_equal 1, steps[1][:sessions]
      end

      def test_session_without_step_one_contributes_nothing
        seed_session("s1", [["checkout", 100]])

        steps = analyze(%w[signup checkout])[:steps]

        assert_equal 0, steps[0][:sessions]
        assert_equal 0, steps[1][:sessions]
      end

      # ── conversion % ──

      def test_conversion_pct_is_relative_to_step_one
        seed_session("c1", [["signup", 100], ["checkout", 200]])
        seed_session("c2", [["signup", 100]])

        steps = analyze(%w[signup checkout])[:steps]

        assert_in_delta 100.0, steps[0][:conversion_pct], 0.01
        assert_in_delta 50.0, steps[1][:conversion_pct], 0.01
      end

      def test_conversion_pct_nil_when_no_sessions_reach_step_one
        steps = analyze(%w[signup checkout])[:steps]

        assert_equal 0, steps[0][:sessions]
        assert_nil steps[0][:conversion_pct]
        assert_nil steps[1][:conversion_pct]
      end

      # ── median inter-step time ──

      def test_median_inter_step_time_is_nearest_rank
        seed_session("m1", [["signup", 100], ["checkout", 200]])  # 100ms
        seed_session("m2", [["signup", 100], ["checkout", 400]])  # 300ms
        seed_session("m3", [["signup", 100], ["checkout", 300]])  # 200ms

        steps = analyze(%w[signup checkout])[:steps]

        assert_nil steps[0][:median_ms_from_previous]
        assert_equal 200, steps[1][:median_ms_from_previous]
      end

      def test_median_nil_without_converting_sessions
        seed_session("m1", [["signup", 100]])

        steps = analyze(%w[signup checkout])[:steps]

        assert_nil steps[1][:median_ms_from_previous]
      end

      # ── drop-off examples ──

      def test_drop_off_examples_carry_last_reached_step_location
        seed_session("dropped", [["signup", 150]], window_id: "w7")
        seed_session("converted", [["signup", 100], ["checkout", 200]])

        steps = analyze(%w[signup checkout])[:steps]

        examples = steps[0][:drop_off_examples]
        assert_equal 1, examples.size
        assert_equal({session_id: "dropped", window_id: "w7", offset_ms: 150}, examples.first)
        # the final step never lists drop-offs (those sessions completed)
        assert_empty steps[1][:drop_off_examples]
      end

      def test_drop_off_examples_capped_per_step
        (FunnelAnalyzer::MAX_EXAMPLES_PER_STEP + 3).times do |i|
          seed_session("d#{i}", [["signup", 100]])
        end

        steps = analyze(%w[signup checkout])[:steps]

        assert_equal FunnelAnalyzer::MAX_EXAMPLES_PER_STEP, steps[0][:drop_off_examples].size
        # counts stay complete past the example cap
        assert_equal FunnelAnalyzer::MAX_EXAMPLES_PER_STEP + 3, steps[0][:sessions]
      end

      def test_mid_funnel_drop_off_recorded_at_the_step_reached
        seed_session("mid", [["a", 100], ["b", 250]], window_id: "w2")

        steps = analyze(%w[a b c])[:steps]

        assert_empty steps[0][:drop_off_examples]
        assert_equal({session_id: "mid", window_id: "w2", offset_ms: 250}, steps[1][:drop_off_examples].first)
      end

      # ── caps / truncation ──

      def test_respects_scan_cap
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 1)
        seed_session("s1", [["signup", 100]])
        seed_session("s2", [["signup", 100]])

        result = analyze(%w[signup checkout])

        assert_equal 1, result[:steps][0][:sessions]
        assert result[:was_truncated]
      end

      def test_explicit_limit_overrides_config
        seed_session("s1", [["signup", 100]])
        seed_session("s2", [["signup", 100]])

        result = analyze(%w[signup checkout], limit: 1)

        assert_equal 1, result[:steps][0][:sessions]
        assert result[:was_truncated]
      end

      def test_not_truncated_under_caps
        seed_session("s1", [["signup", 100], ["checkout", 200]])

        refute analyze(%w[signup checkout])[:was_truncated]
      end

      def test_per_session_step_event_cap_flags_truncation
        cap = FunnelAnalyzer::MAX_STEP_EVENTS_PER_SESSION
        tagged = (cap + 5).times.map { |i| ["signup", i + 1] }
        seed_session("busy", tagged)

        result = analyze(%w[signup checkout])

        assert result[:was_truncated]
        assert_equal 1, result[:steps][0][:sessions]
      end

      # ── since/until bounds ──

      def test_analyze_honors_date_bounds
        seed_session("s1", [["signup", 100], ["checkout", 200]])

        out_of_window = analyze(%w[signup checkout], until_time: Time.now.to_f - 3600)
        in_window = analyze(%w[signup checkout], since: Time.now.to_f - 3600, until_time: Time.now.to_f + 3600)

        assert_equal 0, out_of_window[:steps][0][:sessions]
        assert_equal 1, in_window[:steps][0][:sessions]
      end

      # ── malformed events ──

      def test_ignores_malformed_custom_events
        events = [
          {"type" => 3, "timestamp" => now_ms},
          {"type" => 5, "timestamp" => now_ms + 1, "data" => {"tag" => 42}},
          {"type" => 5, "timestamp" => now_ms + 2, "data" => "nope"},
          {"type" => 5, "timestamp" => now_ms + 3},
          {"type" => 5, "timestamp" => nil, "data" => {"tag" => "signup"}}
        ]
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), events)

        result = analyze(%w[signup checkout])

        # The timestamp-less signup still surfaces in the vocabulary, but it
        # cannot be placed on the timeline, so the chain never starts.
        assert_equal 0, result[:steps][0][:sessions]
        assert_equal ["signup"], result[:tags]
      end
    end
  end
end
