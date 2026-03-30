# frozen_string_literal: true

require "rack"

require_relative "sentiero/version"
require_relative "sentiero/geo_location"
require_relative "sentiero/configuration"
require_relative "sentiero/geo_resolver"
require_relative "sentiero/geo_resolvers/cloudflare_resolver"
require_relative "sentiero/session_metadata"
require_relative "sentiero/geo_filter"
require_relative "sentiero/middleware/geo_capture"

module Sentiero
  class Error < StandardError; end

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
