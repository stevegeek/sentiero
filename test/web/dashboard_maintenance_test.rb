# frozen_string_literal: true

require "test_helper"
require "sentiero/web/dashboard_app"
require "rack/test"

module Sentiero
  module Web
    class DashboardMaintenanceTest < Minitest::Test
      include Rack::Test::Methods

      def app = DashboardApp.new

      def setup
        Sentiero.configure do |c|
          c.store = Sentiero::Stores::Memory.new
          c.allow_insecure_dashboard = true
        end
      end

      def teardown = Sentiero.reset_configuration!

      def test_maintenance_requires_auth
        Sentiero.configuration.allow_insecure_dashboard = false
        get "/maintenance"
        assert_equal 403, last_response.status
      end

      def test_maintenance_page_renders_both_sections
        get "/maintenance"
        assert_equal 200, last_response.status
        assert_includes last_response.body, "Purge recordings before a date"
        assert_includes last_response.body, "Retention"
      end

      def test_maintenance_shows_unset_retention_state
        get "/maintenance"
        assert_includes last_response.body, "kept forever"
        refute_includes last_response.body, "Run retention purge now"
      end

      def test_maintenance_shows_configured_retention
        Sentiero.configuration.retention_period = 30 * 86_400
        get "/maintenance"
        assert_includes last_response.body, "30 days"
        assert_includes last_response.body, "Run retention purge now"
      end

      def test_maintenance_shows_purged_count_notice
        get "/maintenance", {"purged" => "12"}
        assert_includes last_response.body, "Purged 12 session"
      end

      def test_nav_includes_maintenance_link
        get "/"
        assert_match %r{href="[^"]*/maintenance"}, last_response.body
      end

      def test_purge_before_requires_csrf
        post "/maintenance/purge-before", {"date" => "2026-01-01", "confirm" => "1"}
        assert_equal 403, last_response.status
      end

      def test_purge_before_requires_confirm_checkbox
        save_session("no-confirm", Time.now)
        token = csrf_token_for("/maintenance")
        post "/maintenance/purge-before", {"date" => "2026-01-01", "csrf_token" => token}
        follow_redirect!
        assert_includes last_response.body, "confirm"
        refute_nil Sentiero.store.get_session("no-confirm")
      end

      def test_purge_before_rejects_garbage_date
        token = csrf_token_for("/maintenance")
        post "/maintenance/purge-before", {"date" => "not-a-date", "confirm" => "1", "csrf_token" => token}
        follow_redirect!
        assert_includes last_response.body, "date"
      end

      def test_purge_before_deletes_inclusively_up_to_end_of_day_utc
        # Memory store stamps updated_at with Time.now regardless of the
        # timestamp passed in, so a session can't be backdated here.
        save_session("today-1", Time.now)

        token = csrf_token_for("/maintenance")
        yesterday = (Time.now.utc - 86_400).strftime("%Y-%m-%d")
        post "/maintenance/purge-before", {"date" => yesterday, "confirm" => "1", "csrf_token" => token}
        assert_equal 302, last_response.status
        refute_nil Sentiero.store.get_session("today-1"), "today's session must survive a purge dated yesterday"

        today = Time.now.utc.strftime("%Y-%m-%d")
        token = csrf_token_for("/maintenance")
        post "/maintenance/purge-before", {"date" => today, "confirm" => "1", "csrf_token" => token}
        assert_match(/purged=\d+/, last_response.headers["location"])
        assert_nil Sentiero.store.get_session("today-1"), "a purge dated today (inclusive end-of-day) must delete today's session"
      end

      def test_purge_before_audits
        entries = []
        Sentiero.configuration.audit_log = ->(entry) { entries << entry }
        token = csrf_token_for("/maintenance")
        post "/maintenance/purge-before", {"date" => "2020-01-01", "confirm" => "1", "csrf_token" => token}
        assert entries.any? { |e| e[:action] == :erase_where }, "expected an :erase_where audit entry, got #{entries.inspect}"
      end

      def test_purge_expired_requires_csrf
        post "/maintenance/purge-expired", {}
        assert_equal 403, last_response.status
      end

      def test_purge_expired_noop_without_retention_period
        token = csrf_token_for("/maintenance")
        post "/maintenance/purge-expired", {"csrf_token" => token}
        follow_redirect!
        assert_includes last_response.body, "retention_period"
      end

      def test_purge_expired_audits
        Sentiero.configuration.retention_period = 30 * 86_400
        entries = []
        Sentiero.configuration.audit_log = ->(entry) { entries << entry }
        token = csrf_token_for("/maintenance")
        post "/maintenance/purge-expired", {"csrf_token" => token}
        assert entries.any? { |e| e[:action] == :purge }, "expected a :purge audit entry, got #{entries.inspect}"
      end

      def test_purge_expired_deletes_with_retention_period
        Sentiero.configuration.retention_period = 1
        save_session("stale", Time.now)
        sleep 1.1
        token = csrf_token_for("/maintenance")
        post "/maintenance/purge-expired", {"csrf_token" => token}
        assert_match(/purged=\d+/, last_response.headers["location"])
        assert_nil Sentiero.store.get_session("stale")
      end

      private

      def save_session(id, updated_at_time)
        Sentiero.store.save_events(Sentiero::WindowRef.new(id, "w1"),
          [{"timestamp" => updated_at_time.to_f * 1000, "type" => 3}])
      end

      # Mirrors how DashboardApp issues a CSRF token: do a GET that sets the
      # sentiero_csrf cookie, then read it back so the POST can echo it.
      def csrf_token_for(path)
        get path
        cookie = last_response.headers["set-cookie"]
        cookie[/sentiero_csrf=([^;]+)/, 1]
      end
    end
  end
end
