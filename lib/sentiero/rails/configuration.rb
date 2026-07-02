# frozen_string_literal: true

module Sentiero
  module Rails
    class Configuration
      attr_accessor :events_url, :reporter_middleware

      def initialize
        @events_url = "/sentiero/events"
        @reporter_middleware = true
      end
    end

    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration)
      end

      def reset_configuration!
        @configuration = Configuration.new
      end
    end
  end
end
