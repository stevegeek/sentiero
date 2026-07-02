# frozen_string_literal: true

require "test_helper"
require "sentiero/reporter"
require "sentiero/reporter/test_helper"

module Sentiero
  module Reporter
    class TestHelperTest < Minitest::Test
      class Recording
        attr_reader :calls
        def initialize = (@calls = [])
        def post(path, payload) = @calls << [path, payload]
      end

      def setup
        @transport = Recording.new
        Reporter.configure do |c|
          c.endpoint = "http://collector.test"
          c.ingest_key = "k"
          c.project = "app"
          c.async = false
          c.transport = @transport
        end
      end

      def teardown
        Reporter.reset!
      end

      def test_capture_notifications_records_within_block
        captured = TestHelper.capture_notifications do
          Reporter.notify(RuntimeError.new("boom"))
          Reporter.track("signup", session_id: "s1")
        end
        assert_equal 2, captured.size
        assert_equal "errors", captured[0][0]
        assert_equal "RuntimeError", captured[0][1]["exception_class"]
        assert_equal "track", captured[1][0]
        assert_equal "signup", captured[1][1]["name"]
      end

      def test_capture_notifications_restores_previous_transport
        original = Reporter.configuration.transport
        TestHelper.capture_notifications { Reporter.notify(RuntimeError.new("x")) }
        assert_same original, Reporter.configuration.transport
        # original transport saw nothing during capture
        assert_empty @transport.calls
      end

      def test_capture_notifications_restores_transport_even_on_error
        original = Reporter.configuration.transport
        assert_raises(RuntimeError) do
          TestHelper.capture_notifications { raise "host error" }
        end
        assert_same original, Reporter.configuration.transport
      end

      # The module is includable for a bare capture_notifications.
      def test_capture_notifications_is_includable
        klass = Class.new { include TestHelper }
        captured = klass.new.capture_notifications { Reporter.notify(RuntimeError.new("boom")) }
        assert_equal "errors", captured.first.first
      end
    end
  end
end
