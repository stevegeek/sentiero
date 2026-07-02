# frozen_string_literal: true

require "test_helper"
require "sentiero/reporter"
require "sentiero/reporter/middleware"
require "rack/test"

module Sentiero
  module Reporter
    class MiddlewareTest < Minitest::Test
      include Rack::Test::Methods

      class Recording
        attr_reader :calls
        def initialize = (@calls = [])
        def post(path, payload) = @calls << [path, payload]
      end

      def setup
        @transport = Recording.new
        Reporter.configure do |c|
          c.endpoint = "http://x"
          c.ingest_key = "k"
          c.project = "app"
          c.async = false
          c.transport = @transport
        end
      end

      def teardown
        Reporter.reset!
        Sentiero.reset_configuration!
      end

      def boom_app
        ->(_env) { raise ArgumentError, "kaboom" }
      end

      def ok_app
        ->(_env) { [200, {"content-type" => "text/plain"}, ["ok"]] }
      end

      attr_reader :app

      def test_reports_and_reraises_unhandled_exception
        @app = Middleware.new(boom_app)
        assert_raises(ArgumentError) { get "/checkout?token=secret123&q=1" }
        payload = @transport.calls.last.last
        assert_equal "ArgumentError", payload["exception_class"]
        assert_equal "/checkout", payload["context"]["request"]["path"]
        # query param scrubbed by key name
        assert_equal "[FILTERED]", payload["context"]["request"]["params"]["token"]
        assert_equal "1", payload["context"]["request"]["params"]["q"]
      end

      def test_passes_through_successful_requests
        @app = Middleware.new(ok_app)
        get "/"
        assert_equal 200, last_response.status
        assert_empty @transport.calls
      end

      def test_reads_session_id_from_cookie
        @app = Middleware.new(boom_app)
        set_cookie "sentiero_sid=sess_cookie_1"
        set_cookie "sentiero_wid=win_cookie_1"
        assert_raises(ArgumentError) { get "/x" }
        payload = @transport.calls.last.last
        assert_equal "sess_cookie_1", payload["session_id"]
        assert_equal "win_cookie_1", payload["window_id"]
      end

      def test_malformed_query_string_does_not_break_the_app
        mw = Middleware.new(boom_app)
        # Invalid %-encoding must not cause request_context to raise. Drive the
        # middleware directly so the malformed query reaches request_context
        # (rack-test's URI parser rejects "%ZZ" before the app is invoked).
        env = {
          "REQUEST_METHOD" => "GET",
          "PATH_INFO" => "/x",
          "QUERY_STRING" => "bad=%ZZ",
          "REMOTE_ADDR" => "127.0.0.1"
        }
        assert_raises(ArgumentError) { mw.call(env) }
        assert_equal "ArgumentError", @transport.calls.last.last["exception_class"]
      end

      def test_anonymize_ip_is_on_by_default
        @app = Middleware.new(boom_app)
        assert_raises(ArgumentError) { get "/x", {}, {"REMOTE_ADDR" => "203.0.113.45"} }
        payload = @transport.calls.last.last
        assert_equal "203.0.113.0", payload["context"]["request"]["ip"]
      end

      def test_anonymize_ip_truncates_client_ip_before_send
        Sentiero.configuration.anonymize_ip = true
        @app = Middleware.new(boom_app)
        assert_raises(ArgumentError) { get "/x", {}, {"REMOTE_ADDR" => "203.0.113.45"} }
        payload = @transport.calls.last.last
        assert_equal "203.0.113.0", payload["context"]["request"]["ip"]
      end

      def test_anonymize_ip_false_passes_raw_ip
        Sentiero.configuration.anonymize_ip = false
        @app = Middleware.new(boom_app)
        assert_raises(ArgumentError) { get "/x", {}, {"REMOTE_ADDR" => "203.0.113.45"} }
        payload = @transport.calls.last.last
        assert_equal "203.0.113.45", payload["context"]["request"]["ip"]
      end
    end
  end
end
