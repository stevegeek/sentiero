# frozen_string_literal: true

require "test_helper"
require "sentiero/web/basic_auth"
require "rack/test"
require "base64"

module Sentiero
  module Web
    class BasicAuthTest < Minitest::Test
      include Rack::Test::Methods

      def app
        BasicAuth.new(->(_env) { [200, {"content-type" => "text/plain"}, ["secret"]] })
      end

      def teardown = Sentiero.reset_configuration!

      def creds(user, pass)
        {"HTTP_AUTHORIZATION" => "Basic " + Base64.strict_encode64("#{user}:#{pass}")}
      end

      def test_passes_through_when_not_configured
        Sentiero.configure { |c| c.basic_auth = nil }
        get "/"
        assert_equal 200, last_response.status
      end

      def test_401_with_challenge_when_configured_and_no_credentials
        Sentiero.configure { |c| c.basic_auth = {user: "admin", password: "pw"} }
        get "/"
        assert_equal 401, last_response.status
        assert_match(/Basic realm/, last_response.headers["www-authenticate"])
      end

      def test_401_on_wrong_credentials
        Sentiero.configure { |c| c.basic_auth = {user: "admin", password: "pw"} }
        get "/", {}, creds("admin", "WRONG")
        assert_equal 401, last_response.status
      end

      def test_200_on_correct_credentials
        Sentiero.configure { |c| c.basic_auth = {user: "admin", password: "pw"} }
        get "/", {}, creds("admin", "pw")
        assert_equal 200, last_response.status
        assert_equal "secret", last_response.body
      end

      def test_blank_configured_password_rejects_all
        Sentiero.configure { |c| c.basic_auth = {user: "admin", password: ""} }
        get "/", {}, creds("admin", "")
        assert_equal 401, last_response.status
      end

      def test_malformed_authorization_header_is_401
        Sentiero.configure { |c| c.basic_auth = {user: "admin", password: "pw"} }
        get "/", {}, {"HTTP_AUTHORIZATION" => "Basic !!!not-base64!!!"}
        assert_equal 401, last_response.status
      end
    end
  end
end
