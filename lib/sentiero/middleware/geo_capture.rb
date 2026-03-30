# frozen_string_literal: true

module Sentiero
  module Middleware
    class GeoCapture
      ENV_GEO_KEY      = "sentiero.geo_location"
      ENV_METADATA_KEY = "sentiero.session_metadata"

      def initialize(app)
        @app = app
        @resolver = Sentiero.configuration.build_resolver
      end

      def call(env)
        request = Rack::Request.new(env)

        geo = @resolver&.resolve(request)

        metadata = SessionMetadata.new(
          geo_location: geo,
          user_agent: request.user_agent,
          referrer: request.referrer
        )

        env[ENV_GEO_KEY] = geo
        env[ENV_METADATA_KEY] = metadata

        @app.call(env)
      end
    end
  end
end
