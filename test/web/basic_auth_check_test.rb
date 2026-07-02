# frozen_string_literal: true

require "test_helper"
require "sentiero/web/basic_auth_check"
require "base64"

module Sentiero
  module Web
    class BasicAuthCheckTest < Minitest::Test
      def header(user, pass)
        {"HTTP_AUTHORIZATION" => "Basic " + Base64.strict_encode64("#{user}:#{pass}")}
      end

      def test_credentials_blank_detects_empty_password
        assert BasicAuthCheck.credentials_blank?({user: "admin", password: ""})
        assert BasicAuthCheck.credentials_blank?({user: "", password: "pw"})
        assert BasicAuthCheck.credentials_blank?({user: "admin", password: nil})
      end

      def test_credentials_blank_false_when_both_present
        refute BasicAuthCheck.credentials_blank?({user: "admin", password: "pw"})
      end

      def test_authorized_true_on_match
        creds = {user: "admin", password: "pw"}
        assert BasicAuthCheck.authorized?(header("admin", "pw"), creds)
      end

      def test_authorized_false_on_mismatch
        creds = {user: "admin", password: "pw"}
        refute BasicAuthCheck.authorized?(header("admin", "WRONG"), creds)
      end

      def test_authorized_false_on_missing_header
        refute BasicAuthCheck.authorized?({}, {user: "admin", password: "pw"})
      end

      def test_authorized_false_on_malformed_header
        env = {"HTTP_AUTHORIZATION" => "Basic !!!not-base64!!!"}
        refute BasicAuthCheck.authorized?(env, {user: "admin", password: "pw"})
      end

      def test_authorized_false_on_blank_creds
        refute BasicAuthCheck.authorized?(header("admin", ""), {user: "admin", password: ""})
      end
    end
  end
end
