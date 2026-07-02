# frozen_string_literal: true

require_relative "test_transport"

module Sentiero
  module Reporter
    # Test-suite support for asserting what the reporter would have sent.
    # Not loaded by default: require "sentiero/reporter/test_helper".
    module TestHelper
      extend self

      # Runs the block with a synchronous in-memory transport, restores the
      # previous transport, and returns deliveries as [path, payload] pairs.
      def capture_notifications
        recorder = TestTransport.new
        previous_transport = Reporter.configuration.transport
        previous_async = Reporter.configuration.async
        Reporter.configure do |c|
          c.transport = recorder
          c.async = false
        end
        yield
        recorder.deliveries
      ensure
        Reporter.configure do |c|
          c.transport = previous_transport
          c.async = previous_async
        end
      end
    end
  end
end
