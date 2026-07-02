# frozen_string_literal: true

module Sentiero
  module Reporter
    class NullTransport
      attr_reader :delivered

      def initialize
        @delivered = 0
      end

      def post(_path, _payload)
        @delivered += 1
        nil
      end
    end
  end
end
