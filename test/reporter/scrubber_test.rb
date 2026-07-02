# frozen_string_literal: true

require "test_helper"
require "sentiero/reporter/scrubber"

module Sentiero
  module Reporter
    class ScrubberTest < Minitest::Test
      def scrub(obj, keys = Scrubber::DEFAULT_KEYS)
        Scrubber.new(keys).scrub(obj)
      end

      def test_redacts_default_sensitive_keys
        out = scrub({"password" => "hunter2", "name" => "ok", "api_key" => "x"})
        assert_equal "[FILTERED]", out["password"]
        assert_equal "[FILTERED]", out["api_key"]
        assert_equal "ok", out["name"]
      end

      def test_is_case_insensitive_and_symbol_aware
        out = scrub({:Password => "x", "AUTHORIZATION" => "y"})
        assert_equal "[FILTERED]", out[:Password]
        assert_equal "[FILTERED]", out["AUTHORIZATION"]
      end

      def test_recurses_into_nested_hashes_and_arrays
        out = scrub({"user" => {"token" => "t"}, "list" => [{"secret" => "s"}]})
        assert_equal "[FILTERED]", out["user"]["token"]
        assert_equal "[FILTERED]", out["list"][0]["secret"]
      end

      def test_scrubs_against_the_given_key_list
        out = scrub({"badge" => "123", "password" => "x"}, ["badge"])
        assert_equal "[FILTERED]", out["badge"]
        assert_equal "x", out["password"], "only the supplied keys are scrubbed"
      end

      def test_defaults_to_built_in_keys_with_no_argument
        out = Scrubber.new.scrub({"password" => "x", "name" => "ok"})
        assert_equal "[FILTERED]", out["password"]
        assert_equal "ok", out["name"]
      end

      def test_leaves_non_hash_values_untouched
        assert_equal "plain", scrub("plain")
        assert_equal [1, 2], scrub([1, 2])
      end

      def test_redacts_keys_mirrored_from_the_redaction_denylist
        out = scrub({"code" => "4/0AX4Xf...", "otp" => "123456", "auth" => "Bearer x",
                      "sig" => "abc", "signature" => "abc", "session" => "sess_1", "key" => "k"})
        %w[code otp auth sig signature session key].each do |k|
          assert_equal "[FILTERED]", out[k], "expected #{k} to be filtered"
        end
      end

      def test_redacts_oauth_code_otp_and_ip_but_still_allows_unmatched_keys
        out = scrub({"code" => "4/0AX4Xf...", "otp" => "123456", "ip" => "203.0.113.42", "password" => "x", "name" => "ok"})
        assert_equal "[FILTERED]", out["code"]
        assert_equal "[FILTERED]", out["otp"]
        assert_equal "[FILTERED]", out["password"]
        assert_equal "203.0.113.42", out["ip"], "ip is not a scrub key; anonymization is handled separately"
        assert_equal "ok", out["name"]
      end

      def test_redacts_new_keys_when_nested
        out = scrub({"exchange" => {"code" => "4/0AX4Xf..."}, "mfa" => [{"otp" => "123456"}]})
        assert_equal "[FILTERED]", out["exchange"]["code"]
        assert_equal "[FILTERED]", out["mfa"][0]["otp"]
      end

      def test_default_keys_are_a_superset_of_the_redaction_denylist
        assert_empty Sentiero::Redaction::BUILTIN_DENYLIST - Scrubber::DEFAULT_KEYS
      end
    end
  end
end
