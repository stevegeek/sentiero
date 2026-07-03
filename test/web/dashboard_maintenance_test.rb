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
    end
  end
end
