# frozen_string_literal: true

module Sentiero
  module Reporter
    # Transport that records every delivery in memory so host-app tests can
    # assert what the reporter would have sent.
    class TestTransport
      attr_reader :deliveries

      def initialize
        @deliveries = []
      end

      def post(path, payload)
        @deliveries << [path, payload]
        nil
      end

      def payloads_for(path)
        @deliveries.select { |p, _| p == path }.map(&:last)
      end

      def clear
        @deliveries.clear
      end
    end
  end
end
