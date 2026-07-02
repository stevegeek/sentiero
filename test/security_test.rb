# frozen_string_literal: true

# Security, privacy, and vulnerability tests.
# Covers privacy bypass attempts, XSS vectors, CORS edge cases,
# type confusion, ID injection, ID validation, CSRF, directory traversal,
# auth callback error handling, escape_js edge cases, resource limits,
# and secure cookie handling.

require "test_helper"
require "sentiero/web/events_app"
require "sentiero/web/dashboard_app"
require "sentiero/web/analytics_app"
require "sentiero/web/script_tag"
require "rack/test"
require "json"
require "securerandom"
require "stringio"

module Sentiero
  # ─── Right-to-erasure adversarial inputs (GDPR Art. 17) ───
  class ErasureSecurityTest < Minitest::Test
    def setup
      @store = Stores::Memory.new
      Sentiero.configure { |c| c.store = @store }
    end

    def teardown
      Sentiero.reset_configuration!
    end

    def save(session_id)
      @store.save_events(Sentiero::WindowRef.new(session_id, "w1"), [{"timestamp" => 1.0}])
    end

    def test_erase_sessions_rejects_malformed_id_before_deleting_anything
      save("keep-1")
      save("keep-2")

      assert_raises(ArgumentError) do
        Sentiero.erase_sessions(["keep-1", "bad id!", "keep-2"])
      end

      refute_nil @store.get_session("keep-1")
      refute_nil @store.get_session("keep-2")
    end

    def test_erase_sessions_rejects_non_string_id
      assert_raises(ArgumentError) { Sentiero.erase_sessions([{}]) }
      assert_raises(ArgumentError) { Sentiero.erase_sessions([["nested"]]) }
    end

    def test_erase_sessions_rejects_non_string_id_with_invalid_characters
      # A Float stringifies to "1.5"; the "." is outside VALID_ID, so it raises
      # rather than being coerced into a different session's ID.
      assert_raises(ArgumentError) { Sentiero.erase_sessions([1.5]) }
    end

    def test_erase_where_requires_at_least_one_bound
      assert_raises(ArgumentError) { Sentiero.erase_where }
    end

    def test_erase_where_rejects_inverted_range_type_safely
      now = Time.now
      assert_raises(ArgumentError) { Sentiero.erase_where(since: now, until_time: now - 60) }
    end

    def test_erase_where_with_non_time_bound_does_not_silently_erase_everything
      save("keep-1")
      save("keep-2")

      # A bound that cannot be compared as a time must fail loudly rather than
      # be treated as "no bound" and erase every session.
      assert_raises(StandardError) { Sentiero.erase_where(since: Object.new) }

      refute_nil @store.get_session("keep-1")
      refute_nil @store.get_session("keep-2")
    end
  end

  # ─── Privacy bypass attempts on Configuration ───
  class PrivacyBypassTest < Minitest::Test
    def teardown
      Sentiero.reset_configuration!
    end

    def test_password_masking_enforced_when_set_to_nil
      config = Configuration.new
      config.recorder_options = {maskInputOptions: nil}

      opts = config.effective_recorder_options
      assert_equal true, opts[:maskInputOptions][:password]
    end

    def test_password_masking_enforced_when_set_to_false
      config = Configuration.new
      config.recorder_options = {maskInputOptions: false}

      opts = config.effective_recorder_options
      assert_equal true, opts[:maskInputOptions][:password]
    end

    def test_password_masking_enforced_when_set_to_empty_hash
      config = Configuration.new
      config.recorder_options = {maskInputOptions: {}}

      opts = config.effective_recorder_options
      assert_equal true, opts[:maskInputOptions][:password]
    end

    def test_password_masking_enforced_when_set_to_array
      config = Configuration.new
      config.recorder_options = {maskInputOptions: []}

      opts = config.effective_recorder_options
      assert_equal true, opts[:maskInputOptions][:password]
    end

    def test_password_masking_enforced_when_set_to_number
      config = Configuration.new
      config.recorder_options = {maskInputOptions: 0}

      opts = config.effective_recorder_options
      assert_equal true, opts[:maskInputOptions][:password]
    end

    def test_user_can_remove_block_selector_with_nil
      config = Configuration.new
      config.block_selector = nil

      opts = config.effective_recorder_options
      assert_nil opts[:blockSelector]
    end

    def test_user_can_remove_mask_text_selector_with_empty_string
      config = Configuration.new
      config.mask_text_selector = ""

      opts = config.effective_recorder_options
      assert_equal "", opts[:maskTextSelector]
    end

    def test_user_can_add_options_but_enforced_always_wins
      config = Configuration.new
      config.mask_input_options = {password: false, email: false, tel: false}
      config.mask_all_inputs = false
      config.block_selector = nil
      config.mask_text_selector = nil
      config.ignore_selector = nil
      config.sampling = nil

      opts = config.effective_recorder_options
      assert_equal true, opts[:maskInputOptions][:password]
      assert_equal false, opts[:maskInputOptions][:email]
      assert_equal false, opts[:maskInputOptions][:tel]
    end

    def test_deep_nesting_does_not_bypass_password_enforcement
      config = Configuration.new
      config.recorder_options = {
        maskInputOptions: {
          password: false,
          nested: {deeply: {buried: true}}
        }
      }

      opts = config.effective_recorder_options
      assert_equal true, opts[:maskInputOptions][:password]
    end

    def test_string_key_password_does_not_bypass_symbol_enforcement
      config = Configuration.new
      config.recorder_options = {"maskInputOptions" => {"password" => false}}

      opts = config.effective_recorder_options
      assert_equal true, opts[:maskInputOptions][:password]
    end
  end

  # ─── ScriptTag XSS vectors ───
  module Web
    class ScriptTagSecurityTest < Minitest::Test
      def setup
        Sentiero.reset_configuration!
        Sentiero.configure { |c| c.store = Stores::Memory.new }
      end

      def teardown
        Sentiero.reset_configuration!
      end

      def test_xss_via_recorder_url_html_injection
        malicious = '"><script>alert("xss")</script><img src="'
        html = ScriptTag.render(events_url: "/events", recorder_url: malicious)

        refute_includes html, '<script>alert("xss")</script>'
        assert_includes html, "&lt;script&gt;"
      end

      def test_xss_via_recorder_url_event_handler
        malicious = '" onload="alert(1)" data-x="'
        html = ScriptTag.render(events_url: "/events", recorder_url: malicious)

        refute_includes html, 'onload="alert(1)"'
        assert_includes html, "&quot;"
      end

      def test_xss_via_events_url_in_json_config
        malicious = "</script><script>alert(document.cookie)</script>"
        html = ScriptTag.render(events_url: malicious)

        config_block = html[/id="sentiero-config">(.*?)<\/script>/m, 1]
        refute_includes config_block, "</script>"
      end

      def test_xss_via_recorder_options_script_injection
        Sentiero.configure do |c|
          c.allow_insecure_dashboard = true
          c.recorder_options = {
            customSelector: "</script><script>alert(1)</script>"
          }
        end

        html = ScriptTag.render(events_url: "/events")
        config_block = html[/id="sentiero-config">(.*?)<\/script>/m, 1]

        refute_includes config_block, "</script>"
        config = JSON.parse(config_block)
        assert_equal "</script><script>alert(1)</script>",
          config["recorderOptions"]["customSelector"]
      end

      def test_unicode_escape_sequences_in_events_url
        malicious = "/events\u0000<script>alert(1)</script>"
        html = ScriptTag.render(events_url: malicious)

        config_block = html[/id="sentiero-config">(.*?)<\/script>/m, 1]
        refute_includes config_block, "</script>"
      end

      def test_recorder_url_with_javascript_protocol
        html = ScriptTag.render(events_url: "/events", recorder_url: "javascript:alert(1)")

        assert_includes html, "javascript:alert(1)"
        refute_includes html, "<script>alert"
      end

      def test_opt_out_cookie_name_is_escaped_in_json_config
        Sentiero.configure do |c|
          c.allow_insecure_dashboard = true
          c.user_opt_out = true
          c.opt_out_cookie_name = "</script><script>alert(14)</script>"
        end

        html = ScriptTag.render(events_url: "/events")
        config_block = html[/id="sentiero-config">(.*?)<\/script>/m, 1]

        refute_includes config_block, "</script>"
        config = JSON.parse(config_block)
        assert_equal "</script><script>alert(14)</script>", config["optOutCookieName"]
      end
    end

    # ─── DashboardApp security ───
    class DashboardAppSecurityTest < Minitest::Test
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
        seed_test_data
      end

      def teardown
        Sentiero.reset_configuration!
      end

      # ── ID validation on DashboardApp routes ──

      def test_show_returns_400_for_session_id_with_colons
        get "/sessions/evil:colon:id/windows/win-1"

        assert_equal 400, last_response.status,
          "DashboardApp should reject session IDs that don't match ID_FORMAT"
      end

      def test_show_returns_400_for_window_id_with_colons
        get "/sessions/sess-abc1/windows/evil:colon:id"

        assert_equal 400, last_response.status,
          "DashboardApp should reject window IDs that don't match ID_FORMAT"
      end

      def test_events_api_returns_400_for_session_id_with_colons
        get "/api/sessions/evil:id/windows/win-1/events"

        assert_equal 400, last_response.status,
          "Events API should reject session IDs that don't match ID_FORMAT"
      end

      def test_events_api_returns_400_for_window_id_with_colons
        get "/api/sessions/sess-abc1/windows/evil:id/events"

        assert_equal 400, last_response.status,
          "Events API should reject window IDs that don't match ID_FORMAT"
      end

      def test_delete_returns_400_for_session_id_with_colons
        token = set_csrf_cookie
        delete "/sessions/evil:id", {"csrf_token" => token}

        assert_equal 400, last_response.status,
          "Delete endpoint should reject session IDs that don't match ID_FORMAT"
      end

      def test_show_returns_400_for_session_id_with_spaces
        get "/sessions/evil%20space/windows/win-1"

        assert_equal 400, last_response.status,
          "DashboardApp should reject session IDs containing spaces"
      end

      def test_show_returns_400_for_oversized_session_id
        long_id = "a" * 129
        get "/sessions/#{long_id}/windows/win-1"

        assert_equal 400, last_response.status,
          "DashboardApp should reject session IDs longer than 128 characters"
      end

      # ── escape_js_string edge cases ──

      def test_escape_js_string_escapes_u2028_line_separator
        dashboard = DashboardApp.new
        result = dashboard.escape_js_string("test\u2028break")

        assert_includes result, "\\u2028",
          "escape_js_string must escape U+2028 (LINE SEPARATOR)"
        refute_includes result, "\u2028",
          "Raw U+2028 should not remain in the escaped output"
      end

      def test_escape_js_string_escapes_u2029_paragraph_separator
        dashboard = DashboardApp.new
        result = dashboard.escape_js_string("test\u2029end")

        assert_includes result, "\\u2029",
          "escape_js_string must escape U+2029 (PARAGRAPH SEPARATOR)"
        refute_includes result, "\u2029",
          "Raw U+2029 should not remain in the escaped output"
      end

      def test_escape_js_string_escapes_both_u2028_and_u2029_together
        dashboard = DashboardApp.new
        result = dashboard.escape_js_string("before\u2028middle\u2029after")

        assert_includes result, "\\u2028"
        assert_includes result, "\\u2029"
        refute_includes result, "\u2028"
        refute_includes result, "\u2029"
      end

      # ── XSS via store data ──

      def test_window_id_with_html_is_rejected_by_store
        assert_raises(ArgumentError) do
          @store.save_events(Sentiero::WindowRef.new("sess-xss", "<img src=x onerror=alert(1)>"), [
            {"type" => 3, "timestamp" => 1000}
          ])
        end
      end

      def test_session_id_with_html_is_rejected_by_store
        assert_raises(ArgumentError) do
          @store.save_events(Sentiero::WindowRef.new("<script>alert(1)</script>", "win-1"), [
            {"type" => 3, "timestamp" => 1000}
          ])
        end
      end

      # ── Directory traversal variants ──

      def test_directory_traversal_with_null_byte
        get "/assets/style.css%00.js"

        status = last_response.status
        assert_includes [200, 404], status
        if status == 200
          assert_equal "text/css", last_response.headers["content-type"]
        end
      end

      def test_directory_traversal_double_encoded
        get "/assets/%252e%252e/%252e%252e/etc/passwd"

        assert_equal 404, last_response.status
      end

      def test_directory_traversal_with_absolute_path
        get "/assets//etc/passwd"

        assert_equal 404, last_response.status
      end

      # ── ERB templates must not be served as static assets ──

      def test_erb_template_dashboard_not_served_as_asset
        get "/assets/dashboard.html.erb"

        assert_equal 404, last_response.status,
          "ERB templates must not be served as static assets (dashboard.html.erb)"
      end

      def test_erb_template_sessions_index_not_served_as_asset
        get "/assets/sessions_index.html.erb"

        assert_equal 404, last_response.status,
          "ERB templates must not be served as static assets (sessions_index.html.erb)"
      end

      def test_erb_template_session_show_not_served_as_asset
        get "/assets/session_show.html.erb"

        assert_equal 404, last_response.status,
          "ERB templates must not be served as static assets (session_show.html.erb)"
      end

      def test_assets_does_not_list_directories
        get "/assets/"

        refute_equal 200, last_response.status unless last_response.body.empty?
      end

      # ── CSRF edge cases ──

      def test_csrf_with_empty_token_and_empty_cookie
        set_cookie "sentiero_csrf="
        delete "/sessions/sess-1?csrf_token="

        assert_equal 403, last_response.status
        assert_includes last_response.body, "Invalid CSRF token"
      end

      def test_csrf_token_not_reusable_across_different_cookies
        token1 = SecureRandom.hex(32)
        set_cookie "sentiero_csrf=#{token1}"

        delete "/sessions/sess-1?csrf_token=#{SecureRandom.hex(32)}"

        assert_equal 403, last_response.status
      end

      def test_delete_with_csrf_in_post_body_is_accepted
        @store.save_events(Sentiero::WindowRef.new("sess-del", "win-1"), [{"type" => 3, "timestamp" => 1000}])
        token = SecureRandom.hex(32)
        set_cookie "sentiero_csrf=#{token}"

        delete "/sessions/sess-del", {csrf_token: token}

        assert_equal 302, last_response.status
      end

      def test_delete_rejects_csrf_token_from_query_string_only
        token = set_csrf_cookie

        post "/sessions/sess-abc1?_method=delete&csrf_token=#{token}"

        assert_equal 403, last_response.status,
          "Delete should reject CSRF tokens provided only via query string"
      end

      # ── Secure cookie handling ──

      def test_csrf_cookie_includes_secure_flag_over_https
        get "/", {}, {"rack.url_scheme" => "https", "HTTPS" => "on"}

        assert_equal 200, last_response.status
        cookie_header = last_response.headers["set-cookie"]
        assert cookie_header, "Expected Set-Cookie header to be present"
        assert_includes cookie_header, "Secure",
          "CSRF cookie must include Secure flag when served over HTTPS"
      end

      def test_csrf_cookie_omits_secure_flag_over_http
        get "/", {}, {"rack.url_scheme" => "http"}

        assert_equal 200, last_response.status
        cookie_header = last_response.headers["set-cookie"]
        assert cookie_header, "Expected Set-Cookie header to be present"
        refute_includes cookie_header, "Secure",
          "CSRF cookie should not include Secure flag over plain HTTP"
      end

      # ── Auth callback edge cases ──

      def test_auth_callback_returning_nil_denies_access
        Sentiero.configuration.auth_callback = ->(_env) {}

        get "/"

        assert_equal 403, last_response.status
      end

      def test_auth_callback_returning_truthy_value_allows_access
        Sentiero.configuration.auth_callback = ->(_env) { 0 }

        get "/"

        assert_equal 200, last_response.status
      end

      def test_auth_callback_returning_empty_string_allows_access
        Sentiero.configuration.auth_callback = ->(_env) { "" }

        get "/"

        assert_equal 200, last_response.status
      end

      def test_auth_callback_exception_on_index_returns_403
        Sentiero.configuration.auth_callback = ->(_env) { raise "db connection error" }

        get "/"

        assert_equal 403, last_response.status,
          "Auth callback exceptions should be caught and result in 403"
      end

      def test_auth_callback_exception_on_show_returns_403
        Sentiero.configuration.auth_callback = ->(_env) { raise "timeout" }

        get "/sessions/sess-abc1/windows/win-1"

        assert_equal 403, last_response.status,
          "Auth callback exceptions on show route should return 403"
      end

      def test_auth_callback_exception_on_events_api_returns_403
        Sentiero.configuration.auth_callback = ->(_env) { raise "service unavailable" }

        get "/api/sessions/sess-abc1/windows/win-1/events"

        assert_equal 403, last_response.status,
          "Auth callback exceptions on events API should return 403"
      end

      def test_auth_callback_exception_on_delete_returns_403
        Sentiero.configuration.auth_callback = ->(_env) { raise "redis down" }
        token = set_csrf_cookie

        delete "/sessions/sess-abc1", {"csrf_token" => token}

        assert_equal 403, last_response.status,
          "Auth callback exceptions on delete should return 403"
      end

      # ── CSP headers on all authenticated routes ──

      def test_show_page_has_frame_deny_header
        get "/sessions/sess-abc1/windows/win-1"

        assert_equal "DENY", last_response.headers["x-frame-options"]
      end

      def test_csp_does_not_allow_external_scripts
        get "/"

        csp = last_response.headers["content-security-policy"]
        script_src = csp[/script-src ([^;]+)/, 1]
        refute_match(/https?:\/\//, script_src,
          "CSP script-src should not allow external domains")
      end

      def test_csp_does_not_allow_external_styles
        get "/"

        csp = last_response.headers["content-security-policy"]
        style_src = csp[/style-src ([^;]+)/, 1]
        refute_match(/https?:\/\//, style_src,
          "CSP style-src should not allow external domains")
      end

      # ── Pagination parameter injection ──

      def test_negative_page_number_defaults_to_1
        get "/?page=-5"

        assert_equal 200, last_response.status
      end

      def test_non_numeric_page_defaults_gracefully
        get "/?page=abc"

        assert_equal 200, last_response.status
      end

      def test_extremely_large_page_number_does_not_crash
        get "/?page=999999999999"

        assert_equal 200, last_response.status
      end

      def test_negative_per_page_defaults_to_20
        get "/?per_page=-1"

        assert_equal 200, last_response.status
      end

      def test_has_errors_filter_param_cannot_inject_into_pagination_links
        get "/?has_errors=%22%3E%3Cscript%3Ealert(1)%3C/script%3E"

        assert_equal 200, last_response.status
        # only the literal string "true" enables the filter; arbitrary values are inert
        refute_includes last_response.body, "<script>alert(1)</script>"
      end

      def test_has_errors_badge_metadata_is_escaped
        @store.save_metadata("sess-abc1", {"has_errors" => true})

        get "/"

        assert_equal 200, last_response.status
        # the badge renders a static label, no reflected metadata content
        assert_includes last_response.body, "badge-danger"
      end

      # ── Audit log fires only on authorized, CSRF-valid access ──

      def test_audit_log_does_not_fire_on_unauthorized_access
        events = []
        Sentiero.configuration.audit_log = ->(e) { events << e }
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/"

        assert_equal 403, last_response.status
        assert_empty events, "audit_log must not fire for a forbidden request"
      end

      def test_audit_log_does_not_fire_on_delete_without_csrf
        events = []
        Sentiero.configuration.audit_log = ->(e) { events << e }

        delete "/sessions/sess-abc1"

        assert_equal 403, last_response.status
        assert_empty events, "audit_log must not fire when the CSRF check fails"
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

    # ─── AnalyticsApp security ───
    class AnalyticsAppSecurityTest < Minitest::Test
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
      end

      def teardown
        Sentiero.reset_configuration!
      end

      def now_ms
        @now_ms ||= (Time.now.to_f * 1000).round
      end

      def test_overview_requires_auth
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/analytics"

        assert_equal 403, last_response.status
      end

      def test_overview_escapes_metadata_url
        @store.save_events(Sentiero::WindowRef.new("sess-xss", "win-1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("sess-xss", {"url" => '"><script>alert(1)</script>'})

        get "/analytics"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "<script>alert(1)</script>"
      end

      def test_overview_escapes_metadata_referrer
        @store.save_events(Sentiero::WindowRef.new("sess-xss", "win-1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("sess-xss", {"referrer" => "</script><script>alert(2)</script>"})

        get "/analytics"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "<script>alert(2)</script>"
      end

      def test_overview_escapes_custom_event_tag
        @store.save_events(Sentiero::WindowRef.new("sess-xss", "win-1"), [
          {"type" => 5, "timestamp" => now_ms, "data" => {"tag" => "<script>alert(3)</script>"}}
        ])

        get "/analytics"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "<script>alert(3)</script>"
      end

      def test_overview_range_param_injection_falls_back
        get "/analytics?range=%22%3E%3Cscript%3Ealert(4)%3C/script%3E"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "<script>alert(4)</script>"
      end

      def test_segments_requires_auth
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/analytics/segments"

        assert_equal 403, last_response.status
      end

      def test_segments_escapes_url_pattern_filter
        get "/analytics/segments?url_pattern=%22%3E%3Cscript%3Ealert(5)%3C/script%3E"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "<script>alert(5)</script>"
      end

      def test_segments_escapes_metadata_key_filter
        get "/analytics/segments?metadata_key=%22%3E%3Cscript%3Ealert(6)%3C/script%3E"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "<script>alert(6)</script>"
      end

      def test_segments_escapes_metadata_value_filter
        get "/analytics/segments?metadata_value=%22%3E%3Cscript%3Ealert(7)%3C/script%3E"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "<script>alert(7)</script>"
      end

      def test_segments_escapes_metadata_in_session_rows
        @store.save_events(Sentiero::WindowRef.new("sess-xss", "win-1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("sess-xss", {"url" => '"><script>alert(8)</script>'})

        get "/analytics/segments"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "<script>alert(8)</script>"
      end

      def test_segments_unknown_browser_value_does_not_filter
        @store.save_events(Sentiero::WindowRef.new("sess-1", "win-1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("sess-1", {"userAgent" => "Mozilla/5.0 Chrome/120.0 Safari/537.36"})

        get "/analytics/segments?browser=Chrome%22%20onload%3D%22alert(9)"

        assert_equal 200, last_response.status
        # An unrecognized browser value is dropped, so it cannot leak into markup.
        refute_includes last_response.body, "onload"
        assert_includes last_response.body, "sess-1"
      end

      def test_heatmap_requires_auth
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/analytics/heatmap"

        assert_equal 403, last_response.status
      end

      def test_heatmap_json_requires_auth
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/analytics/heatmap.json?url=https%3A%2F%2Fx.test%2F"

        assert_equal 403, last_response.status
      end

      def test_heatmap_escapes_recorded_url_in_picker
        @store.save_events(Sentiero::WindowRef.new("sess-xss", "win-1"), [
          {"type" => 4, "timestamp" => now_ms, "data" => {"width" => 1000, "height" => 1000}},
          {"type" => 3, "timestamp" => now_ms + 1, "data" => {"source" => 2, "type" => 2, "x" => 10, "y" => 10}}
        ])
        @store.save_metadata("sess-xss", {"url" => '"><script>alert(10)</script>'})

        get "/analytics/heatmap"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "<script>alert(10)</script>"
      end

      def test_heatmap_config_json_is_escaped_for_script_context
        get "/analytics/heatmap?url=%3C/script%3E%3Cscript%3Ealert(11)%3C/script%3E"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "</script><script>alert(11)"
      end

      def test_analytics_requires_auth
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/analytics"

        assert_equal 403, last_response.status
      end

      # Client-error rendering moved to DashboardApp /issues?source=client;
      # exercise the escaping there directly (this suite's app is AnalyticsApp).
      def client_errors_body
        _, _, body = DashboardApp.new.call(Rack::MockRequest.env_for("/issues?source=client"))
        body.join
      end

      def test_errors_escapes_message_field
        @store.save_events(Sentiero::WindowRef.new("sess-xss", "win-1"), [
          {"type" => 3, "timestamp" => now_ms},
          {"type" => 5, "timestamp" => now_ms + 1,
           "data" => {"tag" => "error", "payload" => {"message" => "<script>alert(12)</script>"}}}
        ])

        refute_includes client_errors_body, "<script>alert(12)</script>"
      end

      def test_errors_escapes_source_field
        @store.save_events(Sentiero::WindowRef.new("sess-xss", "win-1"), [
          {"type" => 3, "timestamp" => now_ms},
          {"type" => 5, "timestamp" => now_ms + 1,
           "data" => {"tag" => "error", "payload" => {"message" => "ok", "source" => "<script>alert(13)</script>"}}}
        ])

        refute_includes client_errors_body, "<script>alert(13)</script>"
      end

      def test_scroll_requires_auth
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/analytics/scroll"

        assert_equal 403, last_response.status
      end

      def test_scroll_escapes_recorded_url
        @store.save_events(Sentiero::WindowRef.new("sess-xss", "win-1"), [
          {"type" => 4, "timestamp" => now_ms, "data" => {"height" => 800}},
          {"type" => 3, "timestamp" => now_ms + 1, "data" => {"source" => 3, "y" => 400}}
        ])
        @store.save_metadata("sess-xss", {"url" => '"><script>alert(99)</script>'})

        get "/analytics/scroll"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "<script>alert(99)</script>"
      end
    end

    # ─── Analytics export security ───
    # Auth on every route, CSRF on the (POST) downloads, CSV formula-injection
    # guarding, and JSON downloads being inert in an HTML context.
    class ExportSecurityTest < Minitest::Test
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
        end
        Manifest.reset!
      end

      def teardown
        Sentiero.reset_configuration!
      end

      def now_ms
        @now_ms ||= (Time.now.to_f * 1000).round
      end

      def valid_csrf_token
        get "/analytics/export"
        last_response.headers["set-cookie"][/sentiero_csrf=([^;]+)/, 1]
      end

      def test_export_index_requires_auth
        Sentiero.configuration.auth_callback = ->(_env) { false }
        get "/analytics/export"
        assert_equal 403, last_response.status
      end

      def test_export_download_requires_auth
        Sentiero.configuration.auth_callback = ->(_env) { false }
        post "/analytics/export/sessions.csv", {"csrf_token" => "x"}
        assert_equal 403, last_response.status
      end

      def test_export_download_requires_csrf_token
        get "/analytics/export"
        post "/analytics/export/sessions.csv"
        assert_equal 403, last_response.status
      end

      def test_export_download_rejects_get
        get "/analytics/export/sessions.csv"
        # Downloads are POST-only; a GET to the route is Method Not Allowed.
        assert_equal 405, last_response.status
      end

      def test_export_path_traversal_in_dataset_does_not_escape
        token = valid_csrf_token
        post "/analytics/export/..%2F..%2Fetc%2Fpasswd.csv", {"csrf_token" => token}
        refute_equal 200, last_response.status
      end

      def test_export_csv_guards_formula_injection_in_metadata
        @store.save_events(Sentiero::WindowRef.new("evil", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("evil", {"url" => "=cmd|'/c calc'!A1"})

        token = valid_csrf_token
        post "/analytics/export/sessions.csv", {"csrf_token" => token}

        assert_equal 200, last_response.status
        assert_includes last_response.body, "'=cmd"
      end

      def test_export_json_download_is_application_json
        @store.save_events(Sentiero::WindowRef.new("xss", "w1"), [{"type" => 3, "timestamp" => now_ms}])
        @store.save_metadata("xss", {"url" => "https://x.test/<script>alert(1)</script>"})

        token = valid_csrf_token
        post "/analytics/export/sessions.json", {"csrf_token" => token}

        # Served as JSON (not text/html), so a browser will not execute markup in
        # a downloaded file; the raw value still round-trips through the parser.
        assert_equal "application/json", last_response.headers["content-type"]
        data = JSON.parse(last_response.body)
        assert(data["rows"].any? { |r| r.include?("https://x.test/<script>alert(1)</script>") })
      end
    end

    # ─── Shareable replay security ───
    # Auth, the feature gate, ID validation, filename sanitization on the
    # Content-Disposition header, and </script> breakout prevention in the
    # inlined events JSON.
    class ShareableReplaySecurityTest < Minitest::Test
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
          c.shareable_replays = true
        end
        Manifest.reset!
      end

      def teardown
        Sentiero.reset_configuration!
      end

      def now_ms
        @now_ms ||= (Time.now.to_f * 1000).round
      end

      def test_share_requires_auth
        Sentiero.configuration.auth_callback = ->(_env) { false }
        @store.save_events(Sentiero::WindowRef.new("sess-1", "win-1"), [{"type" => 3, "timestamp" => now_ms}])

        get "/analytics/share/sess-1"

        assert_equal 403, last_response.status
      end

      def test_share_404s_when_feature_disabled
        Sentiero.configuration.shareable_replays = false
        @store.save_events(Sentiero::WindowRef.new("sess-1", "win-1"), [{"type" => 3, "timestamp" => now_ms}])

        get "/analytics/share/sess-1"

        # 404 (not 403/200) so the route looks like it does not exist when off.
        assert_equal 404, last_response.status
      end

      def test_share_rejects_invalid_id_format
        get "/analytics/share/..%2F..%2Fetc%2Fpasswd"

        assert_equal 400, last_response.status
      end

      # The breakout payload is the canonical attack: a </script> embedded in
      # event data. It must be escaped in the inline JSON, never reflected raw.
      def test_share_escapes_script_breakout_in_event_data
        @store.save_events(Sentiero::WindowRef.new("sess-evil", "win-1"), [
          {"type" => 5, "timestamp" => now_ms,
           "data" => {"tag" => "</script><script>alert(1)</script>"}}
        ])

        get "/analytics/share/sess-evil"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "</script><script>alert(1)"
        # The breakout must survive only in its Unicode-escaped form, proving
        # escape_json was applied to the event data (not the player's own tags).
        assert_includes last_response.body, "\\u003c/script\\u003e"
      end

      def test_share_filename_is_sanitized
        @store.save_events(Sentiero::WindowRef.new("sess-1", "win-1"), [{"type" => 3, "timestamp" => now_ms}])

        get "/analytics/share/sess-1"

        disposition = last_response.headers["content-disposition"]
        assert_includes disposition, 'filename="session-sess-1.html"'
        refute_match(%r{filename="[^"]*[/\\.][^"]*\.html"}, disposition,
          "Filename must not contain path separators or extra dots")
      end

      def test_share_served_as_html_with_nosniff
        @store.save_events(Sentiero::WindowRef.new("sess-1", "win-1"), [{"type" => 3, "timestamp" => now_ms}])

        get "/analytics/share/sess-1"

        assert_equal "text/html", last_response.headers["content-type"]
        assert_equal "nosniff", last_response.headers["x-content-type-options"]
      end
    end

    # ─── EventsApp security ───
    class EventsAppSecurityTest < Minitest::Test
      include Rack::Test::Methods

      def app
        EventsApp.new
      end

      def setup
        Sentiero.configure do |c|
          c.allow_insecure_dashboard = true
          c.store = Stores::Memory.new
          c.cors_origins = []
        end
      end

      def teardown
        Sentiero.reset_configuration!
      end

      # ── Type confusion ──

      def test_integer_session_id_returns_400
        payload = {"sessionId" => 12345, "windowId" => "win-1",
                   "events" => [{"type" => 3}]}
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
        assert_includes JSON.parse(last_response.body)["error"], "sessionId"
      end

      def test_array_session_id_returns_400
        payload = {"sessionId" => ["sess-1"], "windowId" => "win-1",
                   "events" => [{"type" => 3}]}
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
      end

      def test_object_session_id_returns_400
        payload = {"sessionId" => {"id" => "sess-1"}, "windowId" => "win-1",
                   "events" => [{"type" => 3}]}
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
      end

      def test_null_session_id_returns_400
        payload = {"sessionId" => nil, "windowId" => "win-1",
                   "events" => [{"type" => 3}]}
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
      end

      def test_boolean_window_id_returns_400
        payload = {"sessionId" => "sess-1", "windowId" => true,
                   "events" => [{"type" => 3}]}
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
      end

      def test_events_as_string_returns_400
        payload = {"sessionId" => "sess-1", "windowId" => "win-1",
                   "events" => "not an array"}
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
      end

      def test_events_as_object_returns_400
        payload = {"sessionId" => "sess-1", "windowId" => "win-1",
                   "events" => {"type" => 3}}
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
      end

      # ── ID injection ──

      def test_session_id_with_newlines_returns_400
        payload = {"sessionId" => "sess\n\r\ninjected", "windowId" => "win-1",
                   "events" => [{"type" => 3}]}
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
      end

      def test_session_id_with_null_byte_returns_400
        payload = {"sessionId" => "sess\x00id", "windowId" => "win-1",
                   "events" => [{"type" => 3}]}
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
      end

      def test_session_id_with_dots_returns_400
        payload = {"sessionId" => "../../../etc/passwd", "windowId" => "win-1",
                   "events" => [{"type" => 3}]}
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
      end

      def test_session_id_with_html_returns_400
        payload = {"sessionId" => "<script>alert(1)</script>", "windowId" => "win-1",
                   "events" => [{"type" => 3}]}
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
      end

      # ── CORS edge cases ──

      def test_cors_does_not_reflect_arbitrary_origin
        Sentiero.configuration.cors_origins = ["https://trusted.com"]

        post "/", JSON.generate(valid_payload), {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ORIGIN" => "https://evil.com"
        }

        assert_nil last_response.headers["access-control-allow-origin"]
      end

      def test_cors_does_not_match_partial_origin
        Sentiero.configuration.cors_origins = ["https://example.com"]

        post "/", JSON.generate(valid_payload), {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ORIGIN" => "https://evil-example.com"
        }

        assert_nil last_response.headers["access-control-allow-origin"]
      end

      def test_cors_does_not_match_subdomain
        Sentiero.configuration.cors_origins = ["https://example.com"]

        post "/", JSON.generate(valid_payload), {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ORIGIN" => "https://sub.example.com"
        }

        assert_nil last_response.headers["access-control-allow-origin"]
      end

      def test_cors_rejects_null_origin
        Sentiero.configuration.cors_origins = ["https://trusted.com"]

        post "/", JSON.generate(valid_payload), {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ORIGIN" => "null"
        }

        assert_nil last_response.headers["access-control-allow-origin"]
      end

      def test_cors_rejects_empty_origin
        Sentiero.configuration.cors_origins = ["https://trusted.com"]

        post "/", JSON.generate(valid_payload), {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ORIGIN" => ""
        }

        assert_nil last_response.headers["access-control-allow-origin"]
      end

      def test_cors_with_no_origin_header
        Sentiero.configuration.cors_origins = ["https://trusted.com"]

        post "/", JSON.generate(valid_payload), {"CONTENT_TYPE" => "application/json"}

        assert_nil last_response.headers["access-control-allow-origin"]
      end

      def test_cors_multiple_origins_only_matches_exact
        Sentiero.configuration.cors_origins = [
          "https://app1.com",
          "https://app2.com"
        ]

        post "/", JSON.generate(valid_payload), {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ORIGIN" => "https://app2.com"
        }

        assert_equal "https://app2.com", last_response.headers["access-control-allow-origin"]
      end

      # ── Empty/malformed body ──

      def test_empty_body_returns_400
        post "/", "", {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
      end

      def test_content_type_does_not_affect_processing
        post "/", JSON.generate(valid_payload), {"CONTENT_TYPE" => "text/plain"}

        assert_equal 200, last_response.status
      end

      # ── Timestamp validation ──

      def test_timestamp_infinity_string_rejected
        payload = valid_payload.merge(
          "events" => [{"type" => 3, "timestamp" => "Infinity"}]
        )
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status,
          "Timestamp 'Infinity' should be rejected"
        body = JSON.parse(last_response.body)
        assert_includes body["error"].downcase, "timestamp"
      end

      def test_timestamp_negative_infinity_string_rejected
        payload = valid_payload.merge(
          "events" => [{"type" => 3, "timestamp" => "-Infinity"}]
        )
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status,
          "Timestamp '-Infinity' should be rejected"
        body = JSON.parse(last_response.body)
        assert_includes body["error"].downcase, "timestamp"
      end

      def test_timestamp_infinity_not_stored
        payload = valid_payload.merge(
          "events" => [{"type" => 3, "timestamp" => "Infinity"}]
        )
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        events = Sentiero.store.get_events(Sentiero::WindowRef.new("sess-1", "win-1"))
        events.each do |event|
          next unless event["timestamp"]
          refute event["timestamp"].infinite?,
            "Infinite timestamp was stored: #{event["timestamp"]}"
        end
      end

      # ── Resource limits: max_events_per_request ──

      def test_max_events_per_request_enforced
        Sentiero.configuration.max_events_per_request = 100

        events = Array.new(200) { |i| {"type" => 3, "timestamp" => 1000 + i} }
        payload = valid_payload.merge("events" => events)
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status,
          "200 events should be rejected when max_events_per_request is 100"
        body = JSON.parse(last_response.body)
        assert_match(/too many events|events.*limit|max.*events/i, body["error"])
      end

      def test_max_events_per_request_allows_under_limit
        Sentiero.configuration.max_events_per_request = 100

        events = Array.new(50) { |i| {"type" => 3, "timestamp" => 1000 + i} }
        payload = valid_payload.merge("events" => events)
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 200, last_response.status
      end

      def test_max_events_per_request_allows_exactly_at_limit
        Sentiero.configuration.max_events_per_request = 100

        events = Array.new(100) { |i| {"type" => 3, "timestamp" => 1000 + i} }
        payload = valid_payload.merge("events" => events)
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 200, last_response.status
      end

      # ── Resource limits: max_sessions ──

      def test_max_sessions_evicts_oldest_session
        store = Sentiero.store
        store.limits = Sentiero::Store::Limits.new(max_sessions: 5)

        6.times do |i|
          store.save_events(Sentiero::WindowRef.new("session-#{i}", "win-1"), [
            {"type" => 3, "timestamp" => 1000 + i}
          ])
          sleep 0.05
        end

        sessions = store.list_sessions(limit: 100)
        session_ids = sessions.map { |s| s[:session_id] }

        assert_operator sessions.size, :<=, 5,
          "Store should have at most 5 sessions but has #{sessions.size}"
        refute_includes session_ids, "session-0",
          "The oldest session (session-0) should have been evicted"
        assert_includes session_ids, "session-5",
          "The newest session (session-5) should still be present"
      end

      def test_max_sessions_retains_newest_sessions
        store = Sentiero.store
        store.limits = Sentiero::Store::Limits.new(max_sessions: 3)

        5.times do |i|
          store.save_events(Sentiero::WindowRef.new("s-#{i}", "win-1"), [
            {"type" => 3, "timestamp" => 1000 + i}
          ])
          sleep 0.05
        end

        sessions = store.list_sessions(limit: 100)
        session_ids = sessions.map { |s| s[:session_id] }

        assert_equal 3, sessions.size
        assert_includes session_ids, "s-2"
        assert_includes session_ids, "s-3"
        assert_includes session_ids, "s-4"
        refute_includes session_ids, "s-0"
        refute_includes session_ids, "s-1"
      end

      # ── Resource limits: max_events_per_session ──

      def test_max_events_per_session_caps_total_events
        store = Sentiero.store
        store.limits = Sentiero::Store::Limits.new(max_events_per_session: 100)

        first_batch = Array.new(50) { |i| {"type" => 3, "timestamp" => 1000 + i} }
        store.save_events(Sentiero::WindowRef.new("sess-cap", "win-1"), first_batch)

        second_batch = Array.new(60) { |i| {"type" => 3, "timestamp" => 2000 + i} }
        store.save_events(Sentiero::WindowRef.new("sess-cap", "win-1"), second_batch)

        events = store.get_events(Sentiero::WindowRef.new("sess-cap", "win-1"))

        assert_operator events.size, :<=, 100,
          "Session should have at most 100 events but has #{events.size}"
      end

      def test_max_events_per_session_drops_oldest_events
        store = Sentiero.store
        store.limits = Sentiero::Store::Limits.new(max_events_per_session: 100)

        first_batch = Array.new(50) { |i| {"type" => 3, "timestamp" => 1000 + i} }
        store.save_events(Sentiero::WindowRef.new("sess-drop", "win-1"), first_batch)

        second_batch = Array.new(60) { |i| {"type" => 3, "timestamp" => 2000 + i} }
        store.save_events(Sentiero::WindowRef.new("sess-drop", "win-1"), second_batch)

        events = store.get_events(Sentiero::WindowRef.new("sess-drop", "win-1"))
        timestamps = events.map { |e| e["timestamp"] }

        assert_operator events.size, :<=, 100
        assert_includes timestamps, 2059.0,
          "The newest event (timestamp 2059) should be retained"
        refute_includes timestamps, 1000.0,
          "The oldest event (timestamp 1000) should have been dropped"
      end

      def test_max_events_per_session_under_limit_keeps_all
        store = Sentiero.store
        store.limits = Sentiero::Store::Limits.new(max_events_per_session: 100)

        events = Array.new(50) { |i| {"type" => 3, "timestamp" => 1000 + i} }
        store.save_events(Sentiero::WindowRef.new("sess-ok", "win-1"), events)

        stored = store.get_events(Sentiero::WindowRef.new("sess-ok", "win-1"))
        assert_equal 50, stored.size,
          "All 50 events should be kept when under the cap of 100"
      end

      private

      def capture_stderr
        original = $stderr
        $stderr = StringIO.new
        yield
        $stderr.string
      ensure
        $stderr = original
      end

      def valid_payload
        {"sessionId" => "sess-1", "windowId" => "win-1",
         "events" => [{"type" => 3, "timestamp" => 1000}]}
      end
    end

    # ─── Store base class ───
    class StoreBaseTest < Minitest::Test
      def test_save_events_raises_not_implemented
        store = Sentiero::Store.new
        error = assert_raises(NoMethodError) { store.save_events(Sentiero::WindowRef.new("s", "w"), []) }
        assert_includes error.message, "save_events"
      end

      def test_list_sessions_raises_not_implemented
        store = Sentiero::Store.new
        error = assert_raises(NoMethodError) { store.list_sessions(limit: 10) }
        assert_includes error.message, "list_sessions"
      end

      def test_get_session_raises_not_implemented
        store = Sentiero::Store.new
        error = assert_raises(NoMethodError) { store.get_session("s") }
        assert_includes error.message, "get_session"
      end

      def test_get_events_raises_not_implemented
        store = Sentiero::Store.new
        error = assert_raises(NoMethodError) { store.get_events(Sentiero::WindowRef.new("s", "w")) }
        assert_includes error.message, "get_events"
      end

      def test_delete_session_raises_not_implemented
        store = Sentiero::Store.new
        error = assert_raises(NoMethodError) { store.delete_session("s") }
        assert_includes error.message, "delete_session"
      end

      def test_delete_window_raises_not_implemented
        store = Sentiero::Store.new
        error = assert_raises(NoMethodError) { store.delete_window(Sentiero::WindowRef.new("s", "w")) }
        assert_includes error.message, "delete_window"
      end
    end

    # ─── IP anonymization (privacy surface) ───
    # The anonymize_ip config gates a privacy surface: the client IP that reaches
    # the audit_log hook via BaseApp#audit_ip. These cover the masked path (config
    # on), the raw passthrough (config off), and that only the first
    # X-Forwarded-For hop is trusted, so a forged chain cannot smuggle a different
    # address through.
    class IpAnonymizerSecurityTest < Minitest::Test
      include Rack::Test::Methods

      def app
        DashboardApp.new
      end

      def setup
        @store = Stores::Memory.new
        @events = []
        Sentiero.configure do |c|
          c.allow_insecure_dashboard = true
          c.store = @store
          c.auth_callback = nil
          c.audit_log = ->(entry) { @events << entry }
        end
        @store.save_events(Sentiero::WindowRef.new("sess-1", "win-1"), [{"type" => 3, "timestamp" => 1000}])
      end

      def teardown
        Sentiero.reset_configuration!
      end

      def test_anonymize_ip_masks_raw_address
        Sentiero.configuration.anonymize_ip = true

        get "/", {}, {"REMOTE_ADDR" => "203.0.113.45"}

        refute_equal "203.0.113.45", @events.last[:ip]
        assert_equal "203.0.113.0", @events.last[:ip]
      end

      def test_anonymize_ip_disabled_passes_raw_address
        Sentiero.configuration.anonymize_ip = false

        get "/", {}, {"REMOTE_ADDR" => "203.0.113.45"}

        assert_equal "203.0.113.45", @events.last[:ip]
      end

      def test_anonymize_ip_uses_only_first_forwarded_hop
        Sentiero.configuration.anonymize_ip = false

        get "/", {}, {"HTTP_X_FORWARDED_FOR" => "198.51.100.23, 10.0.0.1, 192.168.1.1"}

        assert_equal "198.51.100.23", @events.last[:ip]
      end
    end
  end
end
