# frozen_string_literal: true

require "test_helper"
require "sentiero/web/analytics_app"
require "rack/test"

module Sentiero
  module Web
    # /analytics/funnel page (Plan 22, C3).
    class AnalyticsFunnelPageTest < Minitest::Test
      include Rack::Test::Methods

      def app
        AnalyticsApp.new
      end

      def setup
        @store = Stores::Memory.new
        Sentiero.configure do |c|
          c.allow_insecure_dashboard = true
          c.store = @store
          c.auth_callback = nil
          c.analytics_max_scan_sessions = 5000
        end
        Manifest.reset!
      end

      def teardown
        Sentiero.reset_configuration!
      end

      def now_ms
        @now_ms ||= (Time.now.to_f * 1000).round
      end

      def seed_session(session_id, tagged, window_id: "w1", at: now_ms)
        events = [{"type" => 3, "timestamp" => at}]
        tagged.each do |tag, offset|
          events << {"type" => 5, "timestamp" => at + offset, "data" => {"tag" => tag, "payload" => {}}}
        end
        @store.save_events(Sentiero::WindowRef.new(session_id, window_id), events)
      end

      def test_funnel_returns_200_with_heading
        get "/analytics/funnel"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Funnel"
      end

      def test_funnel_returns_403_when_auth_fails
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/analytics/funnel"

        assert_equal 403, last_response.status
      end

      def test_funnel_sets_security_headers_and_csrf_cookie
        get "/analytics/funnel"

        assert_equal "nosniff", last_response.headers["x-content-type-options"]
        assert_equal "DENY", last_response.headers["x-frame-options"]
        assert last_response.headers["content-security-policy"]
        assert_includes last_response.headers["set-cookie"], "sentiero_csrf="
        assert_includes last_response.headers["set-cookie"], "HttpOnly"
      end

      def test_funnel_renders_step_dropdowns_from_observed_tags
        seed_session("s1", [["signup", 100], ["checkout", 200]])

        get "/analytics/funnel"

        body = last_response.body
        assert_includes body, 'name="step1"'
        assert_includes body, 'name="step2"'
        assert_includes body, 'name="step3"'
        assert_includes body, ">signup</option>"
        assert_includes body, ">checkout</option>"
      end

      def test_funnel_dropdowns_exclude_internal_tags
        seed_session("s1", [["signup", 100], ["__perf", 200], ["__click", 300], ["error", 400]])

        get "/analytics/funnel"

        body = last_response.body
        refute_includes body, "__perf"
        refute_includes body, "__click"
        refute_includes body, ">error</option>"
      end

      def test_funnel_prompts_for_steps_when_none_selected
        seed_session("s1", [["signup", 100]])

        get "/analytics/funnel"

        assert_match(/at least two steps/i, last_response.body)
      end

      def test_funnel_internal_step_params_are_ignored
        seed_session("s1", [["signup", 100], ["__perf", 200]])

        get "/analytics/funnel?step1=signup&step2=__perf"

        # __perf cannot be a step, so only one usable step remains: prompt again.
        assert_match(/at least two steps/i, last_response.body)
      end

      def test_funnel_renders_step_counts_and_conversion
        seed_session("c1", [["signup", 100], ["checkout", 200]])
        seed_session("c2", [["signup", 100]])

        get "/analytics/funnel?step1=signup&step2=checkout"

        body = last_response.body
        assert_includes body, 'data-step-sessions="2"'
        assert_includes body, 'data-step-sessions="1"'
        assert_includes body, 'data-conversion-pct="100.0"'
        assert_includes body, 'data-conversion-pct="50.0"'
      end

      def test_funnel_renders_median_inter_step_time
        seed_session("c1", [["signup", 100], ["checkout", 350]])

        get "/analytics/funnel?step1=signup&step2=checkout"

        # 250ms between the two steps.
        assert_includes last_response.body, "250ms"
      end

      def test_funnel_renders_drop_off_replay_links_at_last_reached_step
        seed_session("dropped", [["signup", 150]], window_id: "w7")
        seed_session("converted", [["signup", 100], ["checkout", 200]])

        get "/analytics/funnel?step1=signup&step2=checkout"

        body = last_response.body
        assert_includes body, "/sessions/dropped/windows/w7?t=150"
        assert_includes body, "Open in player"
        refute_includes body, "/sessions/converted/"
      end

      def test_funnel_shows_empty_state_when_no_sessions_match
        seed_session("s1", [["other", 100], ["thing", 200]])

        get "/analytics/funnel?step1=signup&step2=checkout"

        assert_match(/no sessions/i, last_response.body)
      end

      def test_funnel_escapes_tag_html
        seed_session("s1", [["<script>alert(1)</script>", 100]])

        get "/analytics/funnel"

        refute_includes last_response.body, "<script>alert(1)</script>"
        assert_includes last_response.body, "&lt;script&gt;"
      end

      def test_funnel_truncation_warning_shown_when_capped
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 1)
        seed_session("s1", [["signup", 100]])
        seed_session("s2", [["signup", 100]])

        get "/analytics/funnel?step1=signup&step2=checkout"

        assert_equal 200, last_response.status
        assert_match(/truncat|capp|incomplete/i, last_response.body)
      end

      def test_funnel_renders_from_to_date_inputs
        get "/analytics/funnel"

        assert_includes last_response.body, 'name="since"'
        assert_includes last_response.body, 'name="until"'
      end

      def test_funnel_honors_date_range
        seed_session("s1", [["signup", 100], ["checkout", 200]])
        yesterday = (Time.now.utc.to_date - 1).to_s
        today = Time.now.utc.to_date.to_s

        get "/analytics/funnel?step1=signup&step2=checkout&until=#{yesterday}"
        assert_match(/no sessions/i, last_response.body)

        get "/analytics/funnel?step1=signup&step2=checkout&since=#{today}&until=#{today}"
        assert_includes last_response.body, 'data-step-sessions="1"'
      end

      def test_funnel_form_reflects_selected_steps
        seed_session("s1", [["signup", 100], ["checkout", 200]])

        get "/analytics/funnel?step1=signup&step2=checkout"

        assert_match(/<option[^>]*value="signup"[^>]*selected/, last_response.body)
        assert_match(/<option[^>]*value="checkout"[^>]*selected/, last_response.body)
      end

      def test_funnel_renders_sub_navigation
        get "/analytics/funnel"

        assert_includes last_response.body, "/analytics/vitals"
        assert_includes last_response.body, "/analytics/frustration"
      end
    end
  end
end
