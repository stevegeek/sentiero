# frozen_string_literal: true

require "test_helper"
require "sentiero/web/errors_app"
require "rack/test"
require "json"

module Sentiero
  module Web
    class ErrorsAppTest < Minitest::Test
      include Rack::Test::Methods

      def app = ErrorsApp.new

      def setup
        Sentiero.configure do |c|
          c.store = Stores::Memory.new
          c.ingest_keys = {"k1" => "app"}
        end
      end

      def teardown = Sentiero.reset_configuration!

      def auth = {"HTTP_AUTHORIZATION" => "Bearer k1", "CONTENT_TYPE" => "application/json"}

      def payload(over = {})
        {"exception_class" => "RuntimeError", "message" => "boom",
         "backtrace" => ["app/x.rb:14:in `f'"], "timestamp" => 1000.0}.merge(over)
      end

      def test_valid_post_stores_occurrence_and_returns_fingerprint
        post "/", JSON.generate(payload), auth
        assert_equal 200, last_response.status
        fp = JSON.parse(last_response.body)["fingerprint"]
        refute_nil fp

        problem = Sentiero.store.get_problem(fp)
        assert_equal 1, problem[:count]
        assert_equal "app", problem[:project]
        assert_equal "RuntimeError", problem[:exception_class]
        occ = Sentiero.store.get_occurrences(fp).first
        assert_equal "boom", occ["message"]
      end

      def test_same_error_twice_groups
        post "/", JSON.generate(payload("message" => "boom 1", "backtrace" => ["app/x.rb:14:in `f'"])), auth
        post "/", JSON.generate(payload("message" => "boom 2", "backtrace" => ["app/x.rb:88:in `f'"])), auth
        problems = Sentiero.store.list_problems(project: "app", limit: 10)
        assert_equal 1, problems.size
        assert_equal 2, problems.first[:count]
      end

      def test_session_id_is_stored_for_linkage
        post "/", JSON.generate(payload("session_id" => "sess_8fa2", "window_id" => "win_1")), auth
        fp = JSON.parse(last_response.body)["fingerprint"]
        occ = Sentiero.store.get_occurrences(fp).first
        assert_equal "sess_8fa2", occ["session_id"]
        assert_equal "win_1", occ["window_id"]
      end

      def test_missing_exception_class_is_400
        post "/", JSON.generate(payload.except("exception_class")), auth
        assert_equal 400, last_response.status
      end

      def test_missing_message_is_400
        post "/", JSON.generate(payload.except("message")), auth
        assert_equal 400, last_response.status
      end

      def test_missing_timestamp_defaults_to_now
        post "/", JSON.generate(payload.except("timestamp")), auth
        assert_equal 200, last_response.status
        fp = JSON.parse(last_response.body)["fingerprint"]
        assert_operator Sentiero.store.get_occurrences(fp).first["timestamp"], :>, 0
      end

      def test_invalid_session_id_is_400
        post "/", JSON.generate(payload("session_id" => "bad id!")), auth
        assert_equal 400, last_response.status
      end

      def test_bad_key_is_401
        post "/", JSON.generate(payload), {"HTTP_AUTHORIZATION" => "Bearer nope", "CONTENT_TYPE" => "application/json"}
        assert_equal 401, last_response.status
      end

      def test_bad_key_stores_nothing
        post "/", JSON.generate(payload), {"HTTP_AUTHORIZATION" => "Bearer nope", "CONTENT_TYPE" => "application/json"}
        assert_equal 401, last_response.status
        assert_equal [], Sentiero.store.list_problems(project: "app", limit: 10)
      end

      def test_message_is_truncated
        post "/", JSON.generate(payload("message" => "z" * 99_999)), auth
        fp = JSON.parse(last_response.body)["fingerprint"]
        assert_operator Sentiero.store.get_occurrences(fp).first["message"].length, :<=, ErrorsApp::MAX_MESSAGE_LENGTH
      end

      def test_backtrace_is_truncated
        post "/", JSON.generate(payload("backtrace" => Array.new(500, "app/x.rb:1"))), auth
        fp = JSON.parse(last_response.body)["fingerprint"]
        assert_operator Sentiero.store.get_occurrences(fp).first["backtrace"].length, :<=, ErrorsApp::MAX_BACKTRACE_FRAMES
      end

      def test_anonymizes_incoming_ip_when_configured
        Sentiero.configuration.anonymize_ip = true
        post "/", JSON.generate(payload("context" => {"request" => {"ip" => "203.0.113.42", "path" => "/x"}})), auth
        fp = JSON.parse(last_response.body)["fingerprint"]
        context = Sentiero.store.get_occurrences(fp).first["context"]
        assert_equal "203.0.113.0", context["request"]["ip"]
        assert_equal "/x", context["request"]["path"], "other request fields are untouched"
      end

      def test_disabling_anonymize_ip_keeps_the_raw_ip
        Sentiero.configuration.anonymize_ip = false
        post "/", JSON.generate(payload("context" => {"request" => {"ip" => "203.0.113.42"}})), auth
        fp = JSON.parse(last_response.body)["fingerprint"]
        context = Sentiero.store.get_occurrences(fp).first["context"]
        assert_equal "203.0.113.42", context["request"]["ip"]
      end

      def test_platform_absent_stores_no_platform_key
        post "/", JSON.generate(payload), auth
        fp = JSON.parse(last_response.body)["fingerprint"]
        refute Sentiero.store.get_occurrences(fp).first.key?("platform")
      end

      def test_valid_platform_is_persisted_on_the_occurrence
        post "/", JSON.generate(payload("platform" => "crystal")), auth
        fp = JSON.parse(last_response.body)["fingerprint"]
        assert_equal "crystal", Sentiero.store.get_occurrences(fp).first["platform"]
      end

      def test_mixed_case_platform_is_persisted_downcased
        post "/", JSON.generate(payload("platform" => "Crystal")), auth
        fp = JSON.parse(last_response.body)["fingerprint"]
        assert_equal "crystal", Sentiero.store.get_occurrences(fp).first["platform"]
      end

      def test_crystal_platform_uses_the_crystal_normalizer_for_grouping
        # Same Crystal frame at two different lines/columns: the `ruby`
        # normalizer (tier-1 default) would treat these as distinct fingerprints
        # since Crystal's " in " grammar doesn't match the Ruby `:in` regex; the
        # `crystal` normalizer collapses both to the same fingerprint.
        post "/", JSON.generate(payload("platform" => "crystal", "backtrace" => ["src/app.cr:451 in 'a'"])), auth
        fp1 = JSON.parse(last_response.body)["fingerprint"]

        post "/", JSON.generate(payload("platform" => "crystal", "backtrace" => ["src/app.cr:5:3 in 'a'"])), auth
        fp2 = JSON.parse(last_response.body)["fingerprint"]

        assert_equal fp1, fp2, "crystal frames differing only in line/col should group together"

        problems = Sentiero.store.list_problems(project: "app", limit: 10)
        assert_equal 1, problems.size
        assert_equal 2, problems.first[:count]
      end

      def test_same_crystal_backtraces_without_platform_do_not_group
        # Without the platform tag, the ruby normalizer is a no-op on Crystal's
        # ` in ` grammar, so these two frames remain distinct fingerprints —
        # the contrast case proving the platform tag matters.
        post "/", JSON.generate(payload("backtrace" => ["src/app.cr:451 in 'a'"])), auth
        fp1 = JSON.parse(last_response.body)["fingerprint"]

        post "/", JSON.generate(payload("backtrace" => ["src/app.cr:5:3 in 'a'"])), auth
        fp2 = JSON.parse(last_response.body)["fingerprint"]

        refute_equal fp1, fp2
      end

      def test_invalid_platform_with_spaces_is_treated_as_absent
        post "/", JSON.generate(payload("platform" => "has spaces")), auth
        assert_equal 200, last_response.status
        fp = JSON.parse(last_response.body)["fingerprint"]
        refute Sentiero.store.get_occurrences(fp).first.key?("platform")
      end

      def test_invalid_platform_too_long_is_treated_as_absent
        post "/", JSON.generate(payload("platform" => "x" * 40)), auth
        assert_equal 200, last_response.status
        fp = JSON.parse(last_response.body)["fingerprint"]
        refute Sentiero.store.get_occurrences(fp).first.key?("platform")
      end

      def test_non_string_platform_is_treated_as_absent
        post "/", JSON.generate(payload("platform" => 123)), auth
        assert_equal 200, last_response.status
        fp = JSON.parse(last_response.body)["fingerprint"]
        refute Sentiero.store.get_occurrences(fp).first.key?("platform")
      end
    end
  end
end
