# frozen_string_literal: true

require "json"

module Sentiero
  module Reporter
    # Transport that logs each delivery instead of sending it over the network.
    class LogTransport
      def initialize(io: $stderr, logger: nil, level: :info)
        @io = io
        @logger = logger
        @level = level
      end

      def post(path, payload)
        line = "[Sentiero::Reporter] #{path}: #{JSON.generate(payload)}"
        if @logger
          @logger.public_send(@level, line)
        else
          @io.puts(line)
        end
        nil
      end
    end
  end
end
