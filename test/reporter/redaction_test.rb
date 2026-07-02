# frozen_string_literal: true

require "test_helper"
require "sentiero/reporter"

module Sentiero
  module Reporter
    # The key-based Scrubber only filters whole context keys; it cannot touch PII
    # embedded in the free-text message/backtrace or in payload values. These pin
    # that the value-based Redaction engine runs on those fields before send.
    class RedactionTest < Minitest::Test
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

      def last_payload = @transport.calls.last.last

      def test_redacts_pii_in_exception_message
        Reporter.notify(RuntimeError.new("login failed for jane@example.com"))
        assert_equal "login failed for [redacted]", last_payload["message"]
      end

      def test_redacts_pii_in_backtrace_frames
        e = RuntimeError.new("boom")
        e.set_backtrace(["/srv/app.rb:1 jane@example.com"])
        Reporter.notify(e)
        refute_includes last_payload["backtrace"].join("\n"), "jane@example.com"
      end

      def test_redacts_pii_in_track_payload
        Reporter.track("checkout", note: "ping jane@example.com")
        assert_equal "ping [redacted]", last_payload["payload"]["note"]
      end

      def test_honours_configured_custom_patterns
        Sentiero.configuration.redaction =
          Sentiero::Redaction::Config.new(custom_patterns: [/SECRET-\d+/])
        Reporter.notify(RuntimeError.new("token SECRET-123 leaked"))
        assert_equal "token [redacted] leaked", last_payload["message"]
      end
    end
  end
end
