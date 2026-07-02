# frozen_string_literal: true

require "test_helper"
require "sentiero/web/dashboard_app"
require "rack/test"

module Sentiero
  module Web
    # MonitoringApp owns the /issues/* and /custom-events/* routes. These exercise
    # it both standalone (mounted directly) and through DashboardApp's delegation,
    # mirroring how AnalyticsApp is split out and combined_mount_test.rb verifies it.
    class MonitoringAppMountTest < Minitest::Test
      include Rack::Test::Methods

      def setup
        @store = Stores::Memory.new
        Sentiero.configure do |c|
          c.allow_insecure_dashboard = true
          c.store = @store
          c.auth_callback = nil
        end
        Manifest.reset!
        @store.save_server_event("project" => "app", "name" => "signup", "level" => "info", "timestamp" => 1000.0)
        @store.save_occurrence({"fingerprint" => "fp_mon", "project" => "app",
          "exception_class" => "RuntimeError", "message" => "monitoring boom",
          "timestamp" => 1000.0, "session_id" => "sess_mon", "backtrace" => ["app/x.rb:1:in `f'"]})
      end

      def teardown = Sentiero.reset_configuration!

      # ── standalone mount ──

      def app = MonitoringApp.new

      def test_standalone_issues_index
        get "/issues"
        assert_equal 200, last_response.status
        assert_includes last_response.body, "monitoring boom"
      end

      def test_standalone_issue_show
        get "/issues/fp_mon"
        assert_equal 200, last_response.status
        assert_includes last_response.body, "monitoring boom"
      end

      def test_standalone_custom_events_index
        get "/custom-events"
        assert_equal 200, last_response.status
        assert_includes last_response.body, "signup"
      end

      def test_standalone_preserves_base_path
        status, _, body = MonitoringApp.new.call(
          Rack::MockRequest.env_for("/issues", "SCRIPT_NAME" => "/sentiero")
        )
        assert_equal 200, status
        assert_includes body.join, "/sentiero/"
      end

      # ── delegation through DashboardApp ──

      def test_dashboard_delegates_issues
        status, _, body = DashboardApp.new.call(Rack::MockRequest.env_for("/issues"))
        assert_equal 200, status
        assert_includes body.join, "monitoring boom"
      end

      def test_dashboard_delegates_custom_events
        status, _, body = DashboardApp.new.call(Rack::MockRequest.env_for("/custom-events"))
        assert_equal 200, status
        assert_includes body.join, "signup"
      end
    end
  end
end
