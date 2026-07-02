# frozen_string_literal: true

require "test_helper"
require "sentiero/web/dashboard_app"
require "sentiero/web/assets_app"
require "rack/test"

module Sentiero
  module Web
    # A direct Rack mount (Roda/Sinatra) has no secure-by-default auth the way the
    # Rails generator does. With neither config.basic_auth nor config.auth_callback
    # set, #authorized? fails CLOSED (403); opting into config.allow_insecure_dashboard
    # serves it unauthenticated and emits a one-time boot warning. These tests pin
    # both the fail-closed default and that warning.
    class DashboardNoAuthWarningTest < Minitest::Test
      include Rack::Test::Methods

      def app
        DashboardApp.new
      end

      def setup
        Sentiero.configure do |c|
          c.store = Sentiero::Stores::Memory.new
          c.basic_auth = nil
          c.auth_callback = nil
          c.allow_insecure_dashboard = true
        end
        BaseApp.reset_auth_warning!
      end

      def teardown
        Sentiero.reset_configuration!
        BaseApp.reset_auth_warning!
      end

      def test_warns_when_dashboard_mounted_insecurely
        _out, err = capture_io { DashboardApp.new }
        assert_match(/allow_insecure_dashboard/i, err)
        assert_match(/basic_auth/, err)
      end

      def test_warns_when_analytics_app_mounted_insecurely
        _out, err = capture_io { AnalyticsApp.new }
        assert_match(/allow_insecure_dashboard/i, err)
      end

      def test_fails_closed_with_no_auth_and_no_opt_in
        Sentiero.configuration.allow_insecure_dashboard = false
        _out, _err = capture_io { get "/" }
        assert_equal 403, last_response.status
      end

      def test_does_not_warn_with_no_auth_and_no_opt_in
        Sentiero.configuration.allow_insecure_dashboard = false
        _out, err = capture_io { DashboardApp.new }
        assert_empty err
      end

      def test_no_warning_when_basic_auth_configured
        Sentiero.configuration.basic_auth = {user: "admin", password: "pw"}
        _out, err = capture_io { DashboardApp.new }
        assert_empty err
      end

      def test_no_warning_when_auth_callback_configured
        Sentiero.configuration.auth_callback = ->(_env) { true }
        _out, err = capture_io { DashboardApp.new }
        assert_empty err
      end

      def test_warns_only_once_per_process
        _out, err = capture_io do
          DashboardApp.new
          DashboardApp.new
          AnalyticsApp.new
        end
        assert_equal 1, err.scan(/allow_insecure_dashboard/i).length
      end

      def test_assets_app_never_warns
        # AssetsApp serves only public static assets; it is intentionally
        # unauthenticated and must not trigger the dashboard auth warning.
        _out, err = capture_io { AssetsApp.new }
        assert_empty err
      end
    end
  end
end
