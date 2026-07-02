# frozen_string_literal: true

require "test_helper"
require "sentiero/web/dashboard_app"
require "sentiero/web/events_app"
require "rack/test"
require "base64"

module Sentiero
  module Web
    class DashboardBasicAuthTest < Minitest::Test
      include Rack::Test::Methods

      def app
        DashboardApp.new
      end

      def setup
        Sentiero.configure do |c|
          c.store = Sentiero::Stores::Memory.new
          c.auth_callback = nil
        end
      end

      def teardown = Sentiero.reset_configuration!

      def header(user, pass)
        {"HTTP_AUTHORIZATION" => "Basic " + Base64.strict_encode64("#{user}:#{pass}")}
      end

      def test_correct_basic_auth_credentials_reach_dashboard
        Sentiero.configuration.basic_auth = {user: "admin", password: "pw"}
        get "/", {}, header("admin", "pw")
        assert_equal 200, last_response.status
      end

      def test_missing_credentials_return_401_with_challenge
        Sentiero.configuration.basic_auth = {user: "admin", password: "pw"}
        get "/"
        assert_equal 401, last_response.status
        assert_match(/Basic realm/, last_response.headers["www-authenticate"])
      end

      def test_wrong_credentials_return_401
        Sentiero.configuration.basic_auth = {user: "admin", password: "pw"}
        get "/", {}, header("admin", "WRONG")
        assert_equal 401, last_response.status
      end

      def test_blank_password_raises_sentiero_error
        Sentiero.configuration.basic_auth = {user: "admin", password: ""}
        assert_raises(Sentiero::Error) { get "/", {}, header("admin", "") }
      end

      def test_nil_basic_auth_falls_through_to_auth_callback
        Sentiero.configuration.basic_auth = nil
        Sentiero.configuration.auth_callback = ->(_env) { false }
        get "/"
        assert_equal 403, last_response.status
      end

      def test_analytics_path_is_gated_without_credentials
        Sentiero.configuration.basic_auth = {user: "admin", password: "pw"}
        get "/analytics"
        assert_equal 401, last_response.status
        assert_match(/Basic realm/, last_response.headers["www-authenticate"])
      end

      def test_events_endpoint_stays_public_when_basic_auth_set
        Sentiero.configuration.basic_auth = {user: "admin", password: "pw"}
        events = EventsApp.new
        payload = JSON.generate({sessionId: "s1", windowId: "w1", events: [{type: 4, timestamp: 1}]})
        env = Rack::MockRequest.env_for("/",
          :method => "POST",
          :input => payload,
          "CONTENT_TYPE" => "application/json")
        status, = events.call(env)
        assert_equal 200, status
      end
    end
  end
end
