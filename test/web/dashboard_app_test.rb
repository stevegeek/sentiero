# frozen_string_literal: true

require "test_helper"
require "sentiero/web/dashboard_app"
require "rack/test"
require "json"
require "securerandom"
require "tmpdir"

module Sentiero
  module Web
    class DashboardAppTest < Minitest::Test
      include Rack::Test::Methods

      def app
        DashboardApp.new
      end

      def setup
        @store = Stores::Memory.new
        Sentiero.configure do |c|
          c.allow_insecure_dashboard = true
          c.store = @store
          c.auth_callback = nil
          c.max_events_per_page = 1_000
        end
        Manifest.reset!
        seed_test_data
      end

      def teardown
        Sentiero.reset_configuration!
      end

      def test_index_returns_200_with_session_list
        get "/"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Sessions"
        assert_includes last_response.body, "sess-abc1"
        assert_includes last_response.body, "sess-abc2"
      end

      def test_index_returns_html_content_type
        get "/"

        assert_equal "text/html", last_response.headers["content-type"]
      end

      def test_index_url_column_is_labeled_last_page
        # C2 (P2.2): the recorder updates metadata url per page load, so the
        # column shows the session's LAST page — label it honestly.
        get "/"

        assert_includes last_response.body, "<th>Last page</th>"
        refute_includes last_response.body, "<th>Page</th>"
      end

      def test_index_contains_layout_elements
        get "/"

        assert_includes last_response.body, "Sentiero"
        assert_includes last_response.body, "s-sidebar"
        assert_includes last_response.body, "s-nav-item"
      end

      def test_index_with_auth_callback_returns_403_when_auth_fails
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/"

        assert_equal 403, last_response.status
        assert_includes last_response.body, "Forbidden"
      end

      def test_index_with_auth_callback_returns_200_when_auth_passes
        Sentiero.configuration.auth_callback = ->(_env) { true }

        get "/"

        assert_equal 200, last_response.status
      end

      def test_index_with_nil_auth_callback_allows_access
        Sentiero.configuration.auth_callback = nil

        get "/"

        assert_equal 200, last_response.status
      end

      def test_index_pagination_defaults
        get "/"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "sess-abc1"
        assert_includes last_response.body, "sess-abc2"
      end

      def test_index_pagination_with_per_page_1
        get "/?page=1&per_page=1"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "page=2"
      end

      def test_index_pagination_page_2
        get "/?page=2&per_page=1"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "page=1"
      end

      # Pins the MAX_PAGE clamp on the dashboard (review A3): an over-int64
      # ?page= used to reach the store as a huge OFFSET and blow up
      # SQLite-backed dashboards; the page number is now clamped to
      # BaseApp::MAX_PAGE before any offset math, like AnalyticsApp already did.
      def test_index_clamps_hostile_page_number_before_the_store
        begin
          require "sqlite3"
        rescue LoadError
          skip "sqlite3 gem not available"
        end
        require "sentiero/stores/sqlite"

        Dir.mktmpdir("sentiero_dashboard_clamp") do |dir|
          Sentiero.configuration.store = Stores::SQLite.new(path: ::File.join(dir, "test.db"))

          get "/?page=99999999999999999999"

          assert_equal 200, last_response.status
        end
      end

      def test_index_per_page_capped_at_100
        get "/?per_page=999999"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "per_page=100"
        refute_includes last_response.body, "per_page=999999"
      end

      def test_index_returns_csp_headers
        get "/"

        assert_equal 200, last_response.status
        csp = last_response.headers["content-security-policy"]
        assert csp, "Expected Content-Security-Policy header to be present"
        assert_includes csp, "default-src 'self'"
        assert_includes csp, "script-src 'self'"
        refute_includes csp, "script-src 'self' 'unsafe-inline'", "script-src should not allow unsafe-inline"
      end

      def test_index_returns_security_headers
        get "/"

        assert_equal "nosniff", last_response.headers["x-content-type-options"]
        assert_equal "DENY", last_response.headers["x-frame-options"]
      end

      def test_index_sets_csrf_cookie
        get "/"

        cookie_header = last_response.headers["set-cookie"]
        assert cookie_header, "Expected Set-Cookie header to be present"
        assert_includes cookie_header, "sentiero_csrf="
        assert_includes cookie_header, "HttpOnly"
        assert_includes cookie_header, "SameSite=Strict"
      end

      def test_show_returns_200_for_existing_session
        get "/sessions/sess-abc1/windows/win-1"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "sess-abc1"
        assert_includes last_response.body, "Session Details"
      end

      def test_show_returns_404_for_missing_session
        get "/sessions/nonexistent/windows/win-1"

        assert_equal 404, last_response.status
        assert_includes last_response.body, "not found"
      end

      def test_show_renders_for_existing_session_with_nonexistent_window
        get "/sessions/sess-abc1/windows/nonexistent-win"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "sess-abc1"
        assert_includes last_response.body, "Session Details"
      end

      def test_show_returns_403_when_auth_fails
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/sessions/sess-abc1/windows/win-1"

        assert_equal 403, last_response.status
      end

      def test_show_contains_player_elements
        get "/sessions/sess-abc1/windows/win-1"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "replayer"
        assert_includes last_response.body, "rrweb-player"
        assert_match %r{/assets/dashboard-[A-Za-z0-9]+\.js}, last_response.body
      end

      def test_show_contains_back_link
        get "/sessions/sess-abc1/windows/win-1"

        assert_includes last_response.body, "&larr; Back"
      end

      def test_show_contains_player_config_json
        get "/sessions/sess-abc1/windows/win-1"

        assert_equal 200, last_response.status
        assert_includes last_response.body, 'id="sentiero-player-config"'
        assert_includes last_response.body, "eventsUrl"
      end

      def test_show_has_no_inline_script_blocks
        get "/sessions/sess-abc1/windows/win-1"

        assert_equal 200, last_response.status
        # Only script tags should be type="application/json" or src="..."
        # No bare <script>...</script> with inline JS
        refute_match %r{<script>}, last_response.body, "Should not contain inline script blocks"
      end

      def test_show_returns_csp_headers
        get "/sessions/sess-abc1/windows/win-1"

        assert_equal 200, last_response.status
        csp = last_response.headers["content-security-policy"]
        assert csp, "Expected Content-Security-Policy header to be present"
        assert_includes csp, "default-src 'self'"
      end

      def test_show_returns_security_headers
        get "/sessions/sess-abc1/windows/win-1"

        assert_equal "nosniff", last_response.headers["x-content-type-options"]
        assert_equal "DENY", last_response.headers["x-frame-options"]
      end

      def test_events_api_returns_json_events
        get "/api/sessions/sess-abc1/windows/win-1/events"

        assert_equal 200, last_response.status
        assert_equal "application/json", last_response.headers["content-type"]
        assert_equal "nosniff", last_response.headers["x-content-type-options"]

        events = JSON.parse(last_response.body)
        assert_kind_of Array, events
        assert_equal 3, events.size
      end

      def test_events_api_with_after_param_returns_filtered_events
        get "/api/sessions/sess-abc1/windows/win-1/events?after=1001"

        assert_equal 200, last_response.status
        events = JSON.parse(last_response.body)
        assert_kind_of Array, events
        assert events.all? { |e| e["timestamp"].to_f > 1001 }
      end

      def test_events_api_returns_empty_for_missing_session
        get "/api/sessions/nonexistent/windows/win-1/events"

        assert_equal 200, last_response.status
        events = JSON.parse(last_response.body)
        assert_equal [], events
      end

      def test_events_api_returns_403_when_auth_fails
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/api/sessions/sess-abc1/windows/win-1/events"

        assert_equal 403, last_response.status
      end

      def test_events_api_respects_max_events_per_page
        Sentiero.configuration.max_events_per_page = 2

        get "/api/sessions/sess-abc1/windows/win-1/events"

        events = JSON.parse(last_response.body)
        assert_equal 2, events.size
      end

      def test_delete_session_removes_session
        token = set_csrf_cookie
        delete "/sessions/sess-abc1", {"csrf_token" => token}

        assert_equal 302, last_response.status
        assert_equal "/", last_response.headers["location"]
        assert_nil @store.get_session("sess-abc1")
      end

      def test_delete_session_via_post_with_method_override
        token = set_csrf_cookie
        post "/sessions/sess-abc1?_method=delete",
          {"csrf_token" => token},
          {"CONTENT_TYPE" => "application/x-www-form-urlencoded"}

        assert_equal 302, last_response.status
        assert_equal "/", last_response.headers["location"]
        assert_nil @store.get_session("sess-abc1")
      end

      def test_delete_session_returns_403_when_auth_fails
        Sentiero.configuration.auth_callback = ->(_env) { false }

        delete "/sessions/sess-abc1"

        assert_equal 403, last_response.status
      end

      def test_delete_without_csrf_token_returns_403
        delete "/sessions/sess-abc1"

        assert_equal 403, last_response.status
        assert_includes last_response.body, "Invalid CSRF token"
      end

      def test_delete_with_wrong_csrf_token_returns_403
        set_csrf_cookie
        delete "/sessions/sess-abc1?csrf_token=wrong_token_value"

        assert_equal 403, last_response.status
        assert_includes last_response.body, "Invalid CSRF token"
      end

      def test_assets_returns_404_for_missing_file
        get "/assets/nonexistent.css"

        assert_equal 404, last_response.status
      end

      def test_assets_prevents_directory_traversal
        get "/assets/../../etc/passwd"

        assert_equal 404, last_response.status
      end

      def test_assets_prevents_directory_traversal_with_encoded_dots
        get "/assets/..%2F..%2Fetc%2Fpasswd"

        assert_equal 404, last_response.status
      end

      def test_unknown_route_returns_404
        get "/unknown/path"

        assert_equal 404, last_response.status
      end

      # Pins the single hoisted auth gate (review A1): with auth failing, every
      # non-asset request answers 403 — including wrong-method requests and
      # unknown paths that previously fell through to 404 — matching
      # AnalyticsApp's existing gate. Fail-closed, and an unauthenticated
      # caller can't use 404-vs-403 as a route-enumeration oracle.
      def test_unauthorized_wrong_method_and_unknown_path_return_403
        Sentiero.configuration.auth_callback = ->(_env) { false }

        put "/custom-events/some-id"
        assert_equal 403, last_response.status

        get "/unknown/path"
        assert_equal 403, last_response.status
      end

      def test_index_shows_duration_column
        get "/"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Duration"
      end

      def test_show_displays_session_duration
        get "/sessions/sess-abc1/windows/win-1"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Duration"
      end

      def test_show_displays_total_events
        get "/sessions/sess-abc1/windows/win-1"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Total Events"
      end

      def test_show_has_copy_link_button
        get "/sessions/sess-abc1/windows/win-1"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Copy Link"
      end

      def test_show_has_download_json_button
        get "/sessions/sess-abc1/windows/win-1"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Download JSON"
      end

      def test_show_hides_share_link_when_shareable_replays_disabled
        get "/sessions/sess-abc1/windows/win-1"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "/analytics/share/sess-abc1"
      end

      def test_show_shows_share_link_when_shareable_replays_enabled
        Sentiero.configuration.shareable_replays = true

        get "/sessions/sess-abc1/windows/win-1"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "/analytics/share/sess-abc1"
        assert_includes last_response.body, "Download HTML"
      end

      def test_bulk_delete_removes_selected_sessions
        token = set_csrf_cookie
        post "/sessions/bulk_delete",
          {"csrf_token" => token, "session_ids" => ["sess-abc1", "sess-abc2"]},
          {"CONTENT_TYPE" => "application/x-www-form-urlencoded"}

        assert_equal 302, last_response.status
        assert_nil @store.get_session("sess-abc1")
        assert_nil @store.get_session("sess-abc2")
      end

      def test_bulk_delete_without_csrf_returns_403
        post "/sessions/bulk_delete",
          {"session_ids" => ["sess-abc1"]},
          {"CONTENT_TYPE" => "application/x-www-form-urlencoded"}

        assert_equal 403, last_response.status
        refute_nil @store.get_session("sess-abc1")
      end

      def test_bulk_delete_ignores_invalid_ids
        token = set_csrf_cookie
        post "/sessions/bulk_delete",
          {"csrf_token" => token, "session_ids" => ["sess-abc1", "../etc/passwd"]},
          {"CONTENT_TYPE" => "application/x-www-form-urlencoded"}

        assert_equal 302, last_response.status
        assert_nil @store.get_session("sess-abc1")
      end

      def test_bulk_delete_returns_403_when_auth_fails
        Sentiero.configuration.auth_callback = ->(_env) { false }

        post "/sessions/bulk_delete",
          {"session_ids" => ["sess-abc1"]},
          {"CONTENT_TYPE" => "application/x-www-form-urlencoded"}

        assert_equal 403, last_response.status
        refute_nil @store.get_session("sess-abc1")
      end

      def test_index_has_select_all_checkbox
        get "/"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "select-all"
      end

      def test_show_has_click_overlay_toggle_button
        get "/sessions/sess-abc1/windows/win-1"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "toggle-clicks"
        assert_includes last_response.body, "Clicks"
      end

      def test_show_has_event_markers_container
        get "/sessions/sess-abc1/windows/win-1"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "event-markers"
      end

      def test_show_has_activity_sidebar_container
        get "/sessions/sess-abc1/windows/win-1"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "activity-sidebar"
        assert_includes last_response.body, "activity-list"
      end

      def test_layout_has_analytics_nav_link
        get "/"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Analytics"
        assert_includes last_response.body, "/analytics"
        refute_includes last_response.body, ">Stats<"
      end

      def test_show_includes_built_dashboard_asset
        get "/sessions/sess-abc1/windows/win-1"

        assert_equal 200, last_response.status
        assert_match %r{/assets/dashboard-[A-Za-z0-9]+\.js}, last_response.body
      end

      def test_index_includes_built_sessions_index_asset
        get "/"

        assert_equal 200, last_response.status
        assert_match %r{/assets/sessions_index-[A-Za-z0-9]+\.js}, last_response.body
      end

      def test_layout_includes_fingerprinted_css
        get "/"

        assert_equal 200, last_response.status
        assert_match %r{/assets/style-[A-Za-z0-9]+\.css}, last_response.body
      end

      def test_built_assets_have_immutable_cache_headers
        manifest = Sentiero::Web::Manifest.manifest
        get "/assets/#{manifest["style"]}"

        assert_equal 200, last_response.status
        assert_includes last_response.headers["cache-control"], "immutable"
        assert_includes last_response.headers["cache-control"], "max-age=31536000"
      end

      def test_show_uses_data_action_attributes
        get "/sessions/sess-abc1/windows/win-1"

        assert_equal 200, last_response.status
        assert_includes last_response.body, 'data-action="copy-link"'
        assert_includes last_response.body, 'data-action="download-json"'
      end

      def test_index_uses_data_action_for_delete
        get "/"

        assert_equal 200, last_response.status
        assert_includes last_response.body, 'data-action="delete-session"'
      end

      def test_session_redirect_picks_most_recent_window
        get "/sessions/sess-abc1"

        assert_equal 302, last_response.status
        assert_includes last_response.headers["location"], "/sessions/sess-abc1/windows/win-2"
      end

      def test_session_redirect_returns_404_for_nonexistent
        get "/sessions/nonexistent"

        assert_equal 404, last_response.status
      end

      def test_session_redirect_returns_403_when_auth_fails
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/sessions/sess-abc1"

        assert_equal 403, last_response.status
      end

      # ── Search, filter, sort at HTTP layer ──

      def test_index_search_filters_by_session_id
        get "/?search=abc1"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "sess-abc1"
        refute_includes last_response.body, "sess-abc2"
      end

      def test_index_search_returns_no_results_for_nonexistent
        get "/?search=nonexistent"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "sess-abc1"
        refute_includes last_response.body, "sess-abc2"
      end

      def test_index_sort_by_event_count
        get "/?sort_by=event_count"

        assert_equal 200, last_response.status
        body = last_response.body
        # sess-abc1 has 4 events, sess-abc2 has 1,  abc1 should appear first
        pos_abc1 = body.index("sess-abc1")
        pos_abc2 = body.index("sess-abc2")
        assert pos_abc1 && pos_abc2, "Both sessions should appear"
        assert pos_abc1 < pos_abc2, "Session with more events should appear first"
      end

      def test_index_sort_by_created_at
        get "/?sort_by=created_at"

        assert_equal 200, last_response.status
      end

      def test_index_since_filter
        # sess-abc2 was created after sess-abc1
        future = (Time.now + 3600).iso8601
        get "/?since=#{future}"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "sess-abc1"
        refute_includes last_response.body, "sess-abc2"
      end

      # --- date-range parse helpers (UTC since/until) ---
      # Regression pins for two live bugs: bare Time.parse interpreted a
      # date-only param in the SERVER's local zone, and a date-only `until`
      # parsed to 00:00 so the selected To-day was silently excluded.

      def with_tz(zone)
        old = ENV["TZ"]
        ENV["TZ"] = zone
        yield
      ensure
        ENV["TZ"] = old
      end

      def parse_helper(name, value)
        DashboardApp.new.send(name, value)
      end

      def test_parse_since_param_date_only_is_utc_midnight_in_every_server_zone
        results = ["UTC", "America/Los_Angeles", "Pacific/Kiritimati"].map { |zone|
          with_tz(zone) { parse_helper(:parse_since_param, "2026-06-10") }
        }

        assert results.all?(Time.utc(2026, 6, 10).to_f),
          "date-only since must parse zone-independently, got #{results.inspect}"
      end

      def test_parse_until_param_date_only_includes_the_whole_to_day
        parsed = parse_helper(:parse_until_param, "2026-06-10")

        # 14:00 UTC on the To-day is INSIDE the range (the old parse cut the
        # range at 00:00, dropping everything on the selected day) ...
        assert_operator Time.utc(2026, 6, 10, 14, 0, 0).to_f, :<=, parsed
        # ... but nothing from the following day leaks in.
        assert_operator parsed, :<, Time.utc(2026, 6, 11).to_f
      end

      def test_parse_until_param_date_only_is_zone_independent
        results = ["UTC", "America/Los_Angeles", "Pacific/Kiritimati"].map { |zone|
          with_tz(zone) { parse_helper(:parse_until_param, "2026-06-10") }
        }

        assert_equal 1, results.uniq.size,
          "date-only until must parse zone-independently, got #{results.inspect}"
      end

      def test_parse_range_params_zoneless_timestamps_are_assumed_utc
        with_tz("America/Los_Angeles") do
          since, until_time = DashboardApp.new.send(:parse_range_params,
            {"since" => "2026-06-10T06:00:00", "until" => "2026-06-10T18:30:00"})

          assert_equal Time.utc(2026, 6, 10, 6).to_f, since
          assert_equal Time.utc(2026, 6, 10, 18, 30).to_f, until_time
        end
      end

      def test_parse_range_params_honors_explicit_offsets
        since, until_time = DashboardApp.new.send(:parse_range_params,
          {"since" => "2026-06-10T06:00:00+02:00", "until" => "2026-06-10T12:00:00Z"})

        assert_equal Time.utc(2026, 6, 10, 4).to_f, since
        assert_equal Time.utc(2026, 6, 10, 12).to_f, until_time
      end

      def test_parse_range_params_invalid_or_blank_values_return_nil
        assert_equal [nil, nil], DashboardApp.new.send(:parse_range_params, {})
        assert_equal [nil, nil], DashboardApp.new.send(:parse_range_params, {"since" => "", "until" => ""})
        assert_equal [nil, nil], DashboardApp.new.send(:parse_range_params, {"since" => "not-a-date", "until" => "2026-99-99"})
      end

      def test_index_until_date_includes_sessions_updated_on_that_day
        # Regression: `until=<today>` must keep sessions updated today visible
        # (a 14:00 update on the To-day used to be excluded by the 00:00 cut).
        get "/?until=#{Time.now.utc.to_date}"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "sess-abc1"
        assert_includes last_response.body, "sess-abc2"
      end

      def test_index_until_date_in_the_past_excludes_today_sessions
        get "/?until=#{Time.now.utc.to_date - 2}"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "sess-abc1"
        refute_includes last_response.body, "sess-abc2"
      end

      # --- has_errors badge + filter ---

      def test_index_displays_error_badge_for_sessions_with_errors
        @store.save_metadata("sess-abc1", {"has_errors" => true})

        get "/"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "badge-danger"
        assert_includes last_response.body, "errors"
      end

      def test_index_no_error_badge_when_no_errors
        get "/"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "badge-danger"
      end

      def test_index_has_errors_filter_shows_only_error_sessions
        @store.save_metadata("sess-abc1", {"has_errors" => true})

        get "/?has_errors=true"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "sess-abc1"
        refute_includes last_response.body, "sess-abc2"
      end

      def test_index_has_errors_filter_checkbox_checked_state_preserved
        get "/?has_errors=true"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "checked"
      end

      def test_index_has_errors_filter_combined_with_search
        @store.save_metadata("sess-abc1", {"has_errors" => true})
        @store.save_metadata("sess-abc2", {"has_errors" => true})

        get "/?has_errors=true&search=abc1"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "sess-abc1"
        refute_includes last_response.body, "sess-abc2"
      end

      def test_index_has_errors_filter_preserved_in_pagination_links
        @store.save_metadata("sess-abc1", {"has_errors" => true})
        @store.save_metadata("sess-abc2", {"has_errors" => true})

        get "/?has_errors=true&per_page=1"

        assert_equal 200, last_response.status
        # both the checkbox and the pagination links carry the filter
        assert_includes last_response.body, "page=2"
        assert_includes last_response.body, "has_errors=true"
      end

      def test_index_has_errors_invalid_value_treated_as_off
        @store.save_metadata("sess-abc1", {"has_errors" => true})

        get "/?has_errors=lolnope"

        assert_equal 200, last_response.status
        # filter off: both sessions visible
        assert_includes last_response.body, "sess-abc1"
        assert_includes last_response.body, "sess-abc2"
      end

      private

      def set_csrf_cookie
        token = SecureRandom.hex(32)
        set_cookie "sentiero_csrf=#{token}"
        token
      end

      def seed_test_data
        @store.save_events(Sentiero::WindowRef.new("sess-abc1", "win-1"), [
          {"type" => 3, "timestamp" => 1000},
          {"type" => 3, "timestamp" => 1001},
          {"type" => 3, "timestamp" => 1002}
        ])
        @store.save_events(Sentiero::WindowRef.new("sess-abc1", "win-2"), [
          {"type" => 3, "timestamp" => 2000}
        ])
        @store.save_events(Sentiero::WindowRef.new("sess-abc2", "win-1"), [
          {"type" => 4, "timestamp" => 3000}
        ])
      end
    end
  end
end
