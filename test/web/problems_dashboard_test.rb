# frozen_string_literal: true

require "test_helper"
require "sentiero/web/dashboard_app"
require "rack/test"

module Sentiero
  module Web
    class ProblemsDashboardTest < Minitest::Test
      include Rack::Test::Methods

      def app = DashboardApp.new

      def setup
        @store = Stores::Memory.new
        Sentiero.configure do |c|
          c.allow_insecure_dashboard = true
          c.store = @store
          c.auth_callback = nil
        end
        Manifest.reset!
        @store.save_occurrence({"fingerprint" => "fp_dash", "project" => "app",
          "exception_class" => "RuntimeError", "message" => "dashboard boom",
          "timestamp" => 1000.0, "session_id" => "sess_dash", "backtrace" => ["app/x.rb:1:in `f'"]})
      end

      def teardown = Sentiero.reset_configuration!

      def csrf
        get "/issues/fp_dash"
        last_response.headers["set-cookie"] =~ /sentiero_csrf=([^;]+)/
        $1
      end

      def test_errors_index_lists_problems
        get "/issues"
        assert_equal 200, last_response.status
        assert_includes last_response.body, "RuntimeError"
        assert_includes last_response.body, "dashboard boom"
      end

      def test_errors_index_has_error_tabs_server_active
        get "/issues"
        body = last_response.body
        assert_includes body, "/issues?source=client" # link to client tab
        assert_includes body, "Server exceptions"
        assert_includes body, "Client JS errors"
        refute_includes body, "See client-side JS errors" # old button gone
      end

      def test_errors_index_forbidden_without_auth
        Sentiero.configuration.auth_callback = ->(_e) { false }
        get "/issues"
        assert_equal 403, last_response.status
      end

      def test_error_show_renders_occurrence_and_sessions
        get "/issues/fp_dash"
        assert_equal 200, last_response.status
        assert_includes last_response.body, "dashboard boom"
        assert_includes last_response.body, "sess_dash" # sessions affected
      end

      def test_error_show_404_for_unknown
        get "/issues/nope"
        assert_equal 404, last_response.status
      end

      # ── Phase 2.1: client-errors branch ──
      def seed_client_error(id, window_id, payload, at: 1_000_000)
        @store.save_events(Sentiero::WindowRef.new(id, window_id), [
          {"type" => 3, "timestamp" => at},
          {"type" => 5, "timestamp" => at + 500, "data" => {"tag" => "error", "payload" => payload}}
        ])
      end

      def test_errors_index_client_renders_groups
        seed_client_error("err-1", "w1", {"message" => "Boom happened", "source" => "app.js", "lineno" => 42})
        get "/issues?source=client"
        assert_equal 200, last_response.status
        body = last_response.body
        assert_includes body, "Boom happened"
        assert_includes body, "app.js"
        # The row links to the detail page; the per-occurrence deep link now
        # lives on that detail page, not inline in the list.
        id = client_group_id("Boom happened")
        assert_includes body, "/issues/client/#{id}"
      end

      def test_errors_index_client_search_empties
        seed_client_error("err-1", "w1", {"message" => "Boom happened"})
        get "/issues?source=client&search=zzznomatch"
        assert_equal 200, last_response.status
        refute_includes last_response.body, "Boom happened"
        assert_includes last_response.body, "Clear filters"
      end

      def test_errors_index_client_sets_csrf_cookie
        get "/issues?source=client"
        assert_includes last_response.headers["set-cookie"], "sentiero_csrf="
      end

      def test_errors_index_client_pagination
        seed_client_error("err-a", "w1", {"message" => "Alpha error"})
        seed_client_error("err-b", "w1", {"message" => "Bravo error"})
        get "/issues?source=client&per_page=1&page=1"
        assert_equal 200, last_response.status
        assert_includes last_response.body, "page=2"
      end

      def test_errors_index_client_filter_has_date_inputs
        get "/issues?source=client"
        assert_includes last_response.body, 'name="since"'
        assert_includes last_response.body, 'name="until"'
      end

      # ── server-issues date range (filters on last_seen) ──

      def test_errors_index_server_filter_has_last_seen_date_inputs
        get "/issues"
        assert_includes last_response.body, 'name="since"'
        assert_includes last_response.body, 'name="until"'
        # The UI labels the bound column: the filter applies to last seen.
        assert_match(/last seen/i, last_response.body)
      end

      def test_errors_index_server_honors_date_range_on_last_seen
        # fp_dash is seeded with timestamp 1000.0 (deep 1970); add a fresh one.
        @store.save_occurrence({"fingerprint" => "fp_fresh", "project" => "app",
          "exception_class" => "ArgumentError", "message" => "fresh boom",
          "timestamp" => Time.now.to_f})
        yesterday = (Time.now.utc.to_date - 1).to_s
        today = Time.now.utc.to_date.to_s

        get "/issues?until=#{yesterday}"
        assert_includes last_response.body, "dashboard boom"
        refute_includes last_response.body, "fresh boom"

        # The To-day is inclusive (regression: until=<today> used to cut at 00:00).
        get "/issues?since=#{today}&until=#{today}"
        assert_includes last_response.body, "fresh boom"
        refute_includes last_response.body, "dashboard boom"
      end

      def test_errors_index_server_pagination_preserves_date_range
        @store.save_occurrence({"fingerprint" => "fp_fresh2", "project" => "app",
          "exception_class" => "ArgumentError", "message" => "another boom",
          "timestamp" => Time.now.to_f})
        today = Time.now.utc.to_date.to_s

        get "/issues?per_page=1&since=#{today}&until=#{today}"

        assert_includes last_response.body, "since=#{today}"
        assert_includes last_response.body, "until=#{today}"
      end

      def test_errors_index_client_honors_date_range
        seed_client_error("err-now", "w1", {"message" => "Fresh boom"}, at: (Time.now.to_f * 1000).round)
        yesterday = (Time.now.utc.to_date - 1).to_s
        today = Time.now.utc.to_date.to_s

        get "/issues?source=client&until=#{yesterday}"
        refute_includes last_response.body, "Fresh boom"

        # The To-day is inclusive (regression: until=<today> used to cut at 00:00).
        get "/issues?source=client&since=#{today}&until=#{today}"
        assert_includes last_response.body, "Fresh boom"
      end

      def test_errors_index_client_pagination_preserves_date_range
        seed_client_error("err-a", "w1", {"message" => "Alpha error"}, at: (Time.now.to_f * 1000).round)
        seed_client_error("err-b", "w1", {"message" => "Bravo error"}, at: (Time.now.to_f * 1000).round)
        today = Time.now.utc.to_date.to_s

        get "/issues?source=client&per_page=1&since=#{today}&until=#{today}"

        assert_includes last_response.body, "since=#{today}"
        assert_includes last_response.body, "until=#{today}"
      end

      # ── B4: occurrence sparkline + 24h/7d/30d counts on problem detail ──

      def seed_trend_occurrence(fingerprint, ts)
        @store.save_occurrence({"fingerprint" => fingerprint, "project" => "app",
          "exception_class" => "E", "message" => "trend boom", "timestamp" => ts,
          "backtrace" => ["a:1"]})
      end

      def test_problem_show_renders_24h_7d_30d_counts
        now = Time.now.to_f
        seed_trend_occurrence("fp_trend", now - 3600)          # within 24h
        seed_trend_occurrence("fp_trend", now - 2 * 86_400)    # within 7d
        seed_trend_occurrence("fp_trend", now - 10 * 86_400)   # within 30d
        seed_trend_occurrence("fp_trend", now - 40 * 86_400)   # outside 30d

        get "/issues/fp_trend"

        body = last_response.body
        assert_includes body, 'data-trend-24h="1"'
        assert_includes body, 'data-trend-7d="2"'
        assert_includes body, 'data-trend-30d="3"'
      end

      def test_problem_show_renders_occurrence_sparkline_bucketed_by_utc_day
        now = Time.now.to_f
        seed_trend_occurrence("fp_spark", now)
        seed_trend_occurrence("fp_spark", now - 10)
        seed_trend_occurrence("fp_spark", now - 5 * 86_400)

        get "/issues/fp_spark"

        body = last_response.body
        assert_includes body, "stats-chart"
        # Today's bar carries both same-day occurrences.
        assert_includes body, 'data-spark-count="2"'
      end

      def test_problem_show_sparkline_empty_note_when_occurrences_predate_window
        seed_trend_occurrence("fp_spark_old", Time.now.to_f - 60 * 86_400)

        get "/issues/fp_spark_old"

        assert_equal 200, last_response.status
        assert_match(/No occurrences in the last 30 days/i, last_response.body)
      end

      # ── B3: "new" badge on /issues rows (uses the ACTIVE range's since) ──

      def test_issues_index_shows_new_badge_inside_active_since
        @store.save_occurrence({"fingerprint" => "fp_badge", "project" => "app",
          "exception_class" => "ArgumentError", "message" => "badge boom",
          "timestamp" => Time.now.to_f})
        today = Time.now.utc.to_date.to_s

        get "/issues?since=#{today}"

        assert_includes last_response.body, "badge boom"
        assert_includes last_response.body, ">new</span>"
      end

      def test_issues_index_no_new_badge_without_active_range
        @store.save_occurrence({"fingerprint" => "fp_badge2", "project" => "app",
          "exception_class" => "ArgumentError", "message" => "badge boom 2",
          "timestamp" => Time.now.to_f})

        get "/issues"

        assert_includes last_response.body, "badge boom 2"
        refute_includes last_response.body, ">new</span>"
      end

      def test_status_update_requires_csrf
        post "/issues/fp_dash/status", {"status" => "resolved"}
        assert_equal 403, last_response.status
        assert_equal "open", @store.get_problem("fp_dash")[:status]
      end

      def test_status_update_with_csrf_resolves
        token = csrf
        # carry the csrf cookie set on the GET into the POST
        post "/issues/fp_dash/status", {"status" => "resolved", "csrf_token" => token}
        assert_equal 303, last_response.status
        assert_equal "resolved", @store.get_problem("fp_dash")[:status]
      end

      def test_replay_page_shows_server_activity_panel
        # session must exist for the replay page
        @store.save_events(Sentiero::WindowRef.new("sess_dash", "win_1"), [{"type" => 3, "timestamp" => 1000.0}])
        get "/sessions/sess_dash/windows/win_1"
        assert_equal 200, last_response.status
        assert_includes last_response.body, "dashboard boom" # the occurrence message
        assert_includes last_response.body, "/issues/fp_dash" # link back to the problem
      end

      def test_replay_panel_is_newest_first_with_both_kinds
        @store.save_events(Sentiero::WindowRef.new("sess_chrono", "win_1"), [{"type" => 3, "timestamp" => 1000.0}])
        @store.save_server_event("project" => "app", "name" => "early_event", "level" => "info", "session_id" => "sess_chrono", "timestamp" => 1.0)
        @store.save_occurrence("fingerprint" => "fp_chrono", "project" => "app", "exception_class" => "RuntimeError", "message" => "later boom", "timestamp" => 2.0, "session_id" => "sess_chrono", "backtrace" => ["a:1"])
        get "/sessions/sess_chrono/windows/win_1"
        assert_equal 200, last_response.status
        body = last_response.body
        assert_operator body.index("later boom"), :<, body.index("early_event"), "newer item should render before older item (newest-first)"
      end

      # Task 18: server-activity markers JSON island with player-relative offsets
      def test_replay_page_emits_server_activity_markers_island
        # rrweb event timestamps are epoch ms; server timestamps are float seconds.
        # First rrweb event = 10_000 ms anchor. Server event at 11.0s -> 11_000 ms
        # -> offset 1000. Exception at 12.0s -> 12_000 ms -> offset 2000.
        @store.save_events(Sentiero::WindowRef.new("sess_mark", "win_1"),
          [{"type" => 3, "timestamp" => 10_000.0}, {"type" => 3, "timestamp" => 13_000.0}])
        @store.save_server_event("project" => "app", "name" => "checkout_started",
          "level" => "info", "session_id" => "sess_mark", "timestamp" => 11.0)
        @store.save_occurrence("fingerprint" => "fp_mark", "project" => "app",
          "exception_class" => "RuntimeError", "message" => "payment exploded",
          "timestamp" => 12.0, "session_id" => "sess_mark", "backtrace" => ["a:1"])

        get "/sessions/sess_mark/windows/win_1"
        assert_equal 200, last_response.status
        body = last_response.body

        m = body.match(%r{<script type="application/json" id="server-activity-markers">(.*?)</script>}m)
        refute_nil m, "expected #server-activity-markers JSON island"
        markers = JSON.parse(m[1])
        assert_equal 2, markers.size

        by_kind = markers.group_by { |x| x["kind"] }
        evt = by_kind["event"].first
        exc = by_kind["exception"].first

        assert_equal 1000, evt["offset_ms"], "server event offset in player ms space (no off-by-1000)"
        assert_equal 2000, exc["offset_ms"], "exception offset in player ms space"
        assert_equal "checkout_started", evt["label"]
        assert_includes exc["label"], "payment exploded"
        assert_includes exc["href"], "/issues/fp_mark"
        assert_match %r{/custom-events/}, evt["href"]
      end

      def test_replay_markers_clamp_negative_offsets_to_zero
        # Server item BEFORE the first rrweb event must clamp to offset 0.
        @store.save_events(Sentiero::WindowRef.new("sess_clamp", "win_1"),
          [{"type" => 3, "timestamp" => 10_000.0}])
        @store.save_server_event("project" => "app", "name" => "too_early",
          "level" => "info", "session_id" => "sess_clamp", "timestamp" => 5.0)
        get "/sessions/sess_clamp/windows/win_1"
        body = last_response.body
        m = body.match(%r{<script type="application/json" id="server-activity-markers">(.*?)</script>}m)
        markers = JSON.parse(m[1])
        assert_equal 0, markers.first["offset_ms"]
      end

      def test_problem_show_forbidden_without_auth
        Sentiero.configuration.auth_callback = ->(_e) { false }
        get "/issues/fp_dash"
        assert_equal 403, last_response.status
      end

      def test_status_update_forbidden_without_auth
        Sentiero.configuration.auth_callback = ->(_e) { false }
        post "/issues/fp_dash/status", {"status" => "resolved"}
        assert_equal 403, last_response.status
      end

      def test_invalid_status_is_rejected_and_does_not_mutate
        token = csrf
        post "/issues/fp_dash/status", {"status" => "banana", "csrf_token" => token}
        assert_equal 400, last_response.status
        assert_equal "open", @store.get_problem("fp_dash")[:status]
      end

      def test_occurrence_deep_links_to_window_and_time
        @store.save_occurrence({"fingerprint" => "fp_dl", "project" => "app",
          "exception_class" => "E", "message" => "boom", "timestamp" => 2.5,
          "session_id" => "sess_dl", "window_id" => "win_dl", "backtrace" => ["a:1"]})
        get "/issues/fp_dl"
        assert_includes last_response.body, "/sessions/sess_dl/windows/win_dl?t=2500"
      end

      # ── B1: facet strip on problem detail (aggregated from the already-fetched
      #       occurrences + session summaries; zero extra store calls) ──

      CHROME_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

      def seed_ctx_occurrence(fingerprint, path:, env: "production", release: "v1", ts: Time.now.to_f)
        @store.save_occurrence({"fingerprint" => fingerprint, "project" => "app",
          "exception_class" => "RuntimeError", "message" => "facet boom",
          "timestamp" => ts, "backtrace" => ["a:1"],
          "context" => {"environment" => env, "release" => release,
                        "request" => {"path" => path, "method" => "GET"}}})
      end

      def test_problem_show_renders_facet_strip_with_aggregated_paths
        seed_ctx_occurrence("fp_facets", path: "/checkout")
        seed_ctx_occurrence("fp_facets", path: "/checkout")
        seed_ctx_occurrence("fp_facets", path: "/cart")

        get "/issues/fp_facets"

        assert_equal 200, last_response.status
        body = last_response.body
        assert_includes body, "data-problem-facets"
        # Labeled honestly: facets cover only the fetched occurrences.
        assert_match(/latest 3 occurrences/i, body)
        assert_includes body, "/checkout"
        assert_includes body, 'data-facet-count="2"'
      end

      def test_problem_show_facets_show_env_and_release_mix
        seed_ctx_occurrence("fp_relmix", path: "/a", env: "staging", release: "1.4.1")
        seed_ctx_occurrence("fp_relmix", path: "/a", env: "production", release: "1.4.2")
        seed_ctx_occurrence("fp_relmix", path: "/a", env: "production", release: "1.4.2")

        get "/issues/fp_relmix"

        body = last_response.body
        assert_includes body, "data-problem-facets"
        assert_includes body, "Environments"
        assert_includes body, "Releases"
        assert_includes body, "staging"
        assert_includes body, "1.4.1"
        assert_includes body, "1.4.2"
      end

      def test_problem_show_release_facet_shows_first_seen_from_min_timestamp
        seed_ctx_occurrence("fp_rel", path: "/a", release: "2.0.0", ts: Time.utc(2026, 6, 2, 12).to_f)
        seed_ctx_occurrence("fp_rel", path: "/a", release: "2.0.0", ts: Time.utc(2026, 6, 1, 12).to_f)

        get "/issues/fp_rel"

        assert_match(/first seen Jun 01/i, last_response.body)
      end

      def test_problem_show_facets_include_browser_mix_from_session_summaries
        # fp_dash's occurrence carries session sess_dash; give that session a
        # window + user agent so the summary resolves a browser.
        @store.save_events(Sentiero::WindowRef.new("sess_dash", "win_1"), [{"type" => 3, "timestamp" => 1000.0}])
        @store.save_metadata("sess_dash", {"userAgent" => CHROME_UA})

        get "/issues/fp_dash"

        body = last_response.body
        assert_includes body, "data-problem-facets"
        assert_includes body, "Browsers"
        assert_includes body, "Chrome"
      end

      def test_problem_show_omits_facets_without_context_or_browser_data
        # fp_dash's occurrence has no context and its session has no metadata,
        # so there is nothing to facet on.
        get "/issues/fp_dash"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "data-problem-facets"
      end

      def test_problem_show_facets_escape_html
        seed_ctx_occurrence("fp_facet_xss", path: "/x<script>alert(1)</script>")

        get "/issues/fp_facet_xss"

        refute_includes last_response.body, "<script>alert(1)</script>"
        assert_includes last_response.body, "&lt;script&gt;"
      end

      def test_problem_detail_renders_occurrence_context_and_fingerprint
        @store.save_occurrence({"fingerprint" => "fp_ctx", "project" => "app",
          "exception_class" => "RuntimeError", "message" => "ctx boom", "timestamp" => 1000.0,
          "backtrace" => ["a:1"], "context" => {"environment" => "production", "release" => "v9",
                                                "request" => {"path" => "/checkout", "ip" => "1.2.3.4"}}})
        get "/issues/fp_ctx"
        assert_equal 200, last_response.status
        assert_includes last_response.body, "production"   # context value rendered
        assert_includes last_response.body, "/checkout"
        assert_includes last_response.body, "fp_ctx"       # fingerprint shown
      end

      def test_errors_index_links_to_client_tab
        get "/issues"
        assert_equal 200, last_response.status
        assert_includes last_response.body, "/issues?source=client"
      end

      def test_server_activity_panel_has_filter_controls_and_attrs
        @store.save_server_event("project" => "app", "name" => "evt_x", "level" => "warn", "session_id" => "sess_dash", "timestamp" => 5.0)
        @store.save_events(Sentiero::WindowRef.new("sess_dash", "win_1"), [{"type" => 3, "timestamp" => 1.0}])
        get "/sessions/sess_dash/windows/win_1"
        assert_includes last_response.body, "data-activity-row"
        assert_includes last_response.body, 'data-activity-kind="event"'
        assert_includes last_response.body, "data-activity-filter-type"
      end

      def test_server_activity_event_rows_link_to_event_detail
        @store.save_events(Sentiero::WindowRef.new("sess_link", "win_1"), [{"type" => 3, "timestamp" => 1.0}])
        @store.save_server_event("project" => "app", "name" => "linkme", "level" => "info", "session_id" => "sess_link", "timestamp" => 2.0)
        id = @store.list_server_events(project: "app", limit: 10).first["id"]
        get "/sessions/sess_link/windows/win_1"
        assert_equal 200, last_response.status
        assert_includes last_response.body, "/custom-events/#{id}"
      end

      # Task 1: pagination on problems list
      def test_problems_index_pagination_page1_shows_cap_and_next_link
        # Seed 3 problems; use per_page=2 to force pagination
        @store.save_occurrence({"fingerprint" => "fp_p1", "project" => "app",
          "exception_class" => "A", "message" => "alpha", "timestamp" => 1.0, "backtrace" => ["a:1"]})
        @store.save_occurrence({"fingerprint" => "fp_p2", "project" => "app",
          "exception_class" => "B", "message" => "beta", "timestamp" => 2.0, "backtrace" => ["a:1"]})
        get "/issues?per_page=2&page=1"
        assert_equal 200, last_response.status
        body = last_response.body
        # page 1 should show at most 2 rows (plus the existing fp_dash from setup)
        # but per_page=2 means only 2 shown
        assert_includes body, "page=2"  # Next link present
        assert_includes body, "Next"
      end

      def test_problems_index_pagination_page2_shows_remaining
        @store.save_occurrence({"fingerprint" => "fp_pg1", "project" => "app",
          "exception_class" => "C", "message" => "charlie", "timestamp" => 3.0, "backtrace" => ["a:1"]})
        @store.save_occurrence({"fingerprint" => "fp_pg2", "project" => "app",
          "exception_class" => "D", "message" => "delta", "timestamp" => 4.0, "backtrace" => ["a:1"]})
        # 3 total (fp_dash + fp_pg1 + fp_pg2), per_page=2 → page 2 has 1 item
        get "/issues?per_page=2&page=2"
        assert_equal 200, last_response.status
        # page 2 content rendered without error
        body = last_response.body
        refute_includes body, "No problems recorded yet"
      end

      # Task 2: sort control on problems list
      def test_problems_index_sort_by_count
        @store.save_occurrence({"fingerprint" => "fp_lo", "project" => "app",
          "exception_class" => "Lo", "message" => "low count", "timestamp" => 1.0, "backtrace" => ["a:1"]})
        # seed multiple occurrences to bump fp_dash count
        @store.save_occurrence({"fingerprint" => "fp_dash", "project" => "app",
          "exception_class" => "RuntimeError", "message" => "dashboard boom again", "timestamp" => 2.0, "backtrace" => ["a:1"]})
        @store.save_occurrence({"fingerprint" => "fp_dash", "project" => "app",
          "exception_class" => "RuntimeError", "message" => "dashboard boom again", "timestamp" => 3.0, "backtrace" => ["a:1"]})
        get "/issues?sort_by=count"
        assert_equal 200, last_response.status
        body = last_response.body
        # fp_dash has higher count, should appear before fp_lo
        assert_operator body.index("dashboard boom"), :<, body.index("low count"),
          "higher-count problem should appear first when sorted by count"
      end

      # Task 3: inline resolve/ignore CSRF
      def test_problems_index_csrf_token_in_body
        get "/issues"
        assert_equal 200, last_response.status
        assert_includes last_response.body, "csrf_token"
      end

      def test_problems_index_inline_resolve_via_csrf
        get "/issues"
        last_response.headers["set-cookie"] =~ /sentiero_csrf=([^;]+)/
        token = $1
        post "/issues/fp_dash/status", {"status" => "resolved", "csrf_token" => token}
        assert_equal 303, last_response.status
        assert_equal "resolved", @store.get_problem("fp_dash")[:status]
      end

      # Task 4: filter-aware empty states
      def test_problems_index_filter_aware_empty_state
        get "/issues?search=zzzznomatch"
        assert_equal 200, last_response.status
        assert_includes last_response.body, "Clear filters"
        refute_includes last_response.body, "No problems recorded yet"
      end

      def test_problems_index_bare_empty_state_without_filters
        # use a fresh store with no problems
        @store = Stores::Memory.new
        Sentiero.configure { |c|
          c.store = @store
          c.auth_callback = nil
        }
        get "/issues"
        assert_equal 200, last_response.status
        assert_includes last_response.body, "No problems recorded yet"
        refute_includes last_response.body, "Clear filters"
      end

      # ── C3 (P2.3): empty tabs cross-reference the populated sibling ──

      def reset_store!
        @store = Stores::Memory.new
        Sentiero.configure { |c|
          c.store = @store
          c.auth_callback = nil
        }
      end

      def test_empty_server_tab_cross_references_client_errors
        reset_store!
        seed_client_error("sess_js", "w1", {"message" => "Sentiero e2e demo error"})

        get "/issues"

        body = last_response.body
        assert_includes body, "No problems recorded yet"
        assert_includes body, 'data-sibling-count="1"'
        assert_includes body, "1 client JS error"
        refute_includes body, "client JS errors" # singular for a count of 1
      end

      def test_empty_client_tab_cross_references_server_problems
        # setup seeded one server problem; the client tab has no JS errors.
        get "/issues?source=client"

        body = last_response.body
        assert_includes body, 'data-sibling-count="1"'
        assert_includes body, "1 server exception"
      end

      def test_empty_server_tab_without_client_errors_has_no_cross_reference
        reset_store!

        get "/issues"

        refute_includes last_response.body, "data-sibling-count"
      end

      def test_filtered_empty_server_tab_has_no_cross_reference
        reset_store!
        seed_client_error("sess_js", "w1", {"message" => "Sentiero e2e demo error"})

        get "/issues?search=zzzznomatch"

        refute_includes last_response.body, "data-sibling-count"
      end

      # Task 5: session summaries on problem show
      def test_problem_show_sessions_affected_links_to_replay
        # seed a session with a window so get_session returns window data
        @store.save_events(Sentiero::WindowRef.new("sess_dash", "win_replay"), [{"type" => 3, "timestamp" => 1000.0}])
        get "/issues/fp_dash"
        assert_equal 200, last_response.status
        body = last_response.body
        # session id shown and linked
        assert_includes body, "sess_dash"
        # link should include window path (get_session finds the window)
        assert_includes body, "/sessions/sess_dash/windows/win_replay"
      end

      def test_problem_show_sessions_affected_handles_missing_session
        # fp_dash has sess_dash as an affected session but we never call save_events,
        # so get_session returns nil — the bare id fallback should still render
        # Setup has a bare occurrence with session_id but no corresponding session.
        # Fresh store: save occurrence without saving session events
        @store2 = Stores::Memory.new
        Sentiero.configure { |c|
          c.store = @store2
          c.auth_callback = nil
        }
        @store2.save_occurrence({"fingerprint" => "fp_nil_sess", "project" => "app",
          "exception_class" => "E", "message" => "boom", "timestamp" => 1.0,
          "session_id" => "sess_missing", "backtrace" => ["a:1"]})
        get "/issues/fp_nil_sess"
        assert_equal 200, last_response.status
        assert_includes last_response.body, "sess_missing"
      end

      # ── Phase 3: redesign (shared partials / tables / classes) ──
      def test_errors_index_uses_underline_tab_classes
        get "/issues"
        body = last_response.body
        # underline tab component, not the old pill buttons
        assert_includes body, 'class="tab '
        assert_includes body, "tab-active"
        refute_includes body, "btn-active"
      end

      def test_errors_index_server_inline_resolve_ignore_present
        get "/issues"
        body = last_response.body
        assert_includes body, 'value="resolved"'
        assert_includes body, 'value="ignored"'
        assert_includes body, "/issues/fp_dash/status"
      end

      def test_errors_index_server_uses_badge_danger_not_error
        get "/issues"
        body = last_response.body
        assert_includes body, "badge-danger"
        refute_includes body, "badge-error"
      end

      def test_errors_index_client_rows_link_to_detail_page
        seed_client_error("err-1", "w1", {"message" => "Boom happened", "source" => "app.js", "lineno" => 42})
        get "/issues?source=client"
        body = last_response.body
        assert_includes body, "data-table"
        # Row is a link to the detail page, not an inline expand of occurrences.
        id = client_group_id("Boom happened")
        assert_includes body, "/issues/client/#{id}"
        refute_includes body, "<details"
        refute_includes body, "Open at error"
        refute_includes body, "/sessions/err-1/windows/w1?t=500"
      end

      def test_errors_index_client_uses_filter_bar_with_hidden_source
        get "/issues?source=client"
        body = last_response.body
        assert_includes body, 'name="source"'
        assert_includes body, 'value="client"'
      end

      # ── client error detail page (/issues/client/:id) ──
      def client_group_id(message)
        Sentiero::Analytics::ErrorDiscovery.new(@store).grouped_errors[:groups]
          .find { |g| g[:message] == message }[:id]
      end

      def test_client_error_show_renders_message_and_replay_link
        seed_client_error("err-1", "w1", {"message" => "Detail boom", "source" => "app.js", "lineno" => 42})
        id = client_group_id("Detail boom")
        get "/issues/client/#{id}"
        assert_equal 200, last_response.status
        body = last_response.body
        assert_includes body, "Detail boom"
        assert_includes body, "app.js"
        assert_includes body, "Open in player"
        assert_includes body, "/sessions/err-1/windows/w1?t=500"
      end

      def test_client_error_show_404_for_unknown
        get "/issues/client/bogus"
        assert_equal 404, last_response.status
      end

      # ── B2: browser/device/page facets on client errors ──

      SAFARI_IPHONE_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

      def test_client_error_show_renders_facet_chips
        seed_client_error("err-1", "w1", {"message" => "Facet boom"})
        @store.save_metadata("err-1", {"userAgent" => CHROME_UA, "url" => "https://ex.com/checkout"})
        id = client_group_id("Facet boom")

        get "/issues/client/#{id}"

        body = last_response.body
        assert_includes body, "data-client-error-facets"
        assert_includes body, "Chrome"
        assert_includes body, "Desktop"
        assert_includes body, "https://ex.com/checkout"
      end

      def test_client_error_show_omits_facets_without_metadata
        seed_client_error("err-1", "w1", {"message" => "Bare boom"})
        id = client_group_id("Bare boom")

        get "/issues/client/#{id}"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "data-client-error-facets"
      end

      def test_client_error_show_escapes_facet_values
        seed_client_error("err-1", "w1", {"message" => "Xss boom"})
        @store.save_metadata("err-1", {"url" => "https://x.test/<script>alert(1)</script>"})
        id = client_group_id("Xss boom")

        get "/issues/client/#{id}"

        refute_includes last_response.body, "<script>alert(1)</script>"
      end

      def test_client_errors_index_shows_dominant_browser_column
        seed_client_error("err-1", "w1", {"message" => "Browser boom"})
        @store.save_metadata("err-1", {"userAgent" => CHROME_UA})

        get "/issues?source=client"

        body = last_response.body
        assert_includes body, ">Browser</th>"
        assert_includes body, 'data-dominant-browser="Chrome"'
      end

      def test_client_errors_index_dominant_browser_counts_others
        # Two Chrome occurrences (two windows of one Chrome session) + one
        # Safari occurrence of the same error: dominant Chrome, 1 other browser.
        seed_client_error("err-c", "w1", {"message" => "Mixed boom"})
        seed_client_error("err-c", "w2", {"message" => "Mixed boom"})
        @store.save_metadata("err-c", {"userAgent" => CHROME_UA})
        seed_client_error("err-s", "w1", {"message" => "Mixed boom"})
        @store.save_metadata("err-s", {"userAgent" => SAFARI_IPHONE_UA})

        get "/issues?source=client"

        body = last_response.body
        assert_includes body, 'data-dominant-browser="Chrome"'
        assert_includes body, 'data-browser-others="1"'
      end

      def test_client_error_show_forbidden_without_auth
        seed_client_error("err-1", "w1", {"message" => "Detail boom"})
        id = client_group_id("Detail boom")
        Sentiero.configuration.auth_callback = ->(_e) { false }
        get "/issues/client/#{id}"
        assert_equal 403, last_response.status
      end

      def test_client_route_not_swallowed_by_status_route
        # /issues/client/:id must reach the show handler, not be parsed as a
        # server fingerprint or a status POST target.
        seed_client_error("err-1", "w1", {"message" => "Routed boom"})
        id = client_group_id("Routed boom")
        get "/issues/client/#{id}"
        assert_equal 200, last_response.status
        assert_includes last_response.body, "Routed boom"
      end
    end
  end
end
