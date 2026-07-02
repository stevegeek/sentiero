# frozen_string_literal: true

require "test_helper"
require "sentiero/web/dashboard_app"
require "sentiero/web/analytics_app"
require "rack/test"
require "securerandom"

module Sentiero
  module Web
    # Covers the config.audit_log hook on DashboardApp: it fires with the right
    # action and session_id on each authorized surface, derives user/ip from the
    # env (anonymizing the IP when configured), records a Time, and never breaks
    # the response when the callback raises.
    class DashboardAuditLogTest < Minitest::Test
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
        Manifest.reset!
        @store.save_events(Sentiero::WindowRef.new("sess-1", "win-1"), [{"type" => 3, "timestamp" => 1000}])
      end

      def teardown
        Sentiero.reset_configuration!
      end

      def last_audit
        @events.last
      end

      def csrf_token
        token = SecureRandom.hex(32)
        set_cookie "sentiero_csrf=#{token}"
        token
      end

      def test_fires_on_list_sessions
        get "/"

        assert_equal :list_sessions, last_audit[:action]
        assert_nil last_audit[:session_id]
      end

      def test_problem_id_included_on_status_change
        @store.save_occurrence({"fingerprint" => "fp_audit", "project" => "app",
          "exception_class" => "RuntimeError", "message" => "audit test", "timestamp" => 1.0})
        token = csrf_token
        post "/issues/fp_audit/status", {"status" => "resolved", "csrf_token" => token}

        status_event = @events.find { |e| e[:action] == :update_problem_status }
        refute_nil status_event
        assert_equal "fp_audit", status_event[:problem_id]
      end

      def test_fires_on_view_session
        get "/sessions/sess-1/windows/win-1"

        assert_equal :view_session, last_audit[:action]
        assert_equal "sess-1", last_audit[:session_id]
        assert_equal "win-1", last_audit[:window_id]
      end

      def test_fires_on_view_session_via_events_api
        get "/api/sessions/sess-1/windows/win-1/events"

        assert_equal :view_session, last_audit[:action]
        assert_equal "sess-1", last_audit[:session_id]
      end

      def test_fires_on_delete_session
        token = csrf_token
        delete "/sessions/sess-1", {"csrf_token" => token}

        assert_equal :delete_session, last_audit[:action]
        assert_equal "sess-1", last_audit[:session_id]
      end

      def test_does_not_fire_on_delete_when_csrf_missing
        delete "/sessions/sess-1"

        assert_empty @events
      end

      def test_fires_per_session_on_bulk_delete
        @store.save_events(Sentiero::WindowRef.new("sess-2", "win-1"), [{"type" => 3, "timestamp" => 1000}])
        token = csrf_token
        post "/sessions/bulk_delete", {"csrf_token" => token, "session_ids" => ["sess-1", "sess-2"]}

        assert_equal [:delete_session, :delete_session], @events.map { |e| e[:action] }
        assert_equal ["sess-1", "sess-2"], @events.map { |e| e[:session_id] }
      end

      def test_does_not_fire_on_bulk_delete_when_csrf_missing
        post "/sessions/bulk_delete", {"session_ids" => ["sess-1"]}

        assert_empty @events
      end

      # ── IP anonymization ──

      def test_anonymizes_ipv4_when_enabled
        Sentiero.configuration.anonymize_ip = true

        get "/", {}, {"REMOTE_ADDR" => "192.168.1.100"}

        assert_equal "192.168.1.0", last_audit[:ip]
      end

      def test_passes_raw_ip_when_anonymization_disabled
        Sentiero.configuration.anonymize_ip = false

        get "/", {}, {"REMOTE_ADDR" => "192.168.1.100"}

        assert_equal "192.168.1.100", last_audit[:ip]
      end

      def test_uses_first_forwarded_for_address
        Sentiero.configuration.anonymize_ip = false

        get "/", {}, {"HTTP_X_FORWARDED_FOR" => "10.0.0.1, 192.168.1.100"}

        assert_equal "10.0.0.1", last_audit[:ip]
      end

      # ── User extraction ──

      def test_user_from_sentiero_user_env
        get "/", {}, {"sentiero.user" => "alice", "REMOTE_USER" => "bob"}

        assert_equal "alice", last_audit[:user]
      end

      def test_user_falls_back_to_remote_user
        get "/", {}, {"REMOTE_USER" => "bob"}

        assert_equal "bob", last_audit[:user]
      end

      def test_user_is_nil_when_absent
        get "/"

        assert_nil last_audit[:user]
      end

      # ── Hash shape ──

      def test_timestamp_is_a_time
        get "/"

        assert_kind_of Time, last_audit[:timestamp]
      end

      def test_includes_request_path
        get "/sessions/sess-1/windows/win-1"

        assert_equal "/sessions/sess-1/windows/win-1", last_audit[:path]
      end

      # ── Error handling ──

      def test_raising_callback_does_not_break_response
        Sentiero.configuration.audit_log = ->(_entry) { raise "audit sink down" }

        get "/"

        assert_equal 200, last_response.status
      end

      def test_no_callback_is_a_noop
        Sentiero.configuration.audit_log = nil

        get "/"

        assert_equal 200, last_response.status
      end
    end

    # Covers the config.audit_log hook on AnalyticsApp: export and share fire
    # only after their auth/CSRF/feature guards pass.
    class AnalyticsAuditLogTest < Minitest::Test
      include Rack::Test::Methods

      def app
        AnalyticsApp.new
      end

      def setup
        @store = Stores::Memory.new
        @events = []
        Sentiero.configure do |c|
          c.allow_insecure_dashboard = true
          c.store = @store
          c.auth_callback = nil
          c.shareable_replays = true
          c.audit_log = ->(entry) { @events << entry }
        end
        Manifest.reset!
        @store.save_events(Sentiero::WindowRef.new("sess-1", "win-1"), [{"type" => 3, "timestamp" => 1000}])
      end

      def teardown
        Sentiero.reset_configuration!
      end

      def last_audit
        @events.last
      end

      def csrf_token
        token = SecureRandom.hex(32)
        set_cookie "sentiero_csrf=#{token}"
        token
      end

      def test_fires_on_export
        token = csrf_token
        post "/analytics/export/sessions.csv", {"csrf_token" => token}

        assert_equal :export, last_audit[:action]
        assert_equal "sessions", last_audit[:dataset]
        assert_nil last_audit[:session_id]
      end

      def test_does_not_fire_on_export_when_csrf_invalid
        post "/analytics/export/sessions.csv", {"csrf_token" => "wrong"}

        assert_empty @events
      end

      def test_fires_on_share
        get "/analytics/share/sess-1"

        assert_equal :share, last_audit[:action]
        assert_equal "sess-1", last_audit[:session_id]
      end

      def test_does_not_fire_on_share_when_session_missing
        get "/analytics/share/does-not-exist"

        assert_empty @events
      end
    end
  end
end
