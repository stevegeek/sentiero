# frozen_string_literal: true

module Sentiero
  # Interface for geo-location resolvers.
  #
  # Implementations must define #resolve(request) returning a GeoLocation or nil.
  module GeoResolver
    def resolve(_request)
      raise NotImplementedError, "#{self.class}#resolve must be implemented"
    end
  end
end
