# frozen_string_literal: true

require "rack/utils"
require_relative "basic_auth_check"

module Sentiero
  module Web
    # Optional HTTP Basic auth middleware for standalone dashboards. Passes
    # through when basic_auth is unset; blank configured credentials lock
    # everyone out (401). Assumes TLS upstream.
    class BasicAuth
      def initialize(app)
        @app = app
      end

      def call(env)
        creds = Sentiero.configuration.basic_auth
        return @app.call(env) if creds.nil?
        return @app.call(env) if BasicAuthCheck.authorized?(env, creds)

        [401,
          {"content-type" => "text/plain", "www-authenticate" => 'Basic realm="Sentiero"'},
          ["Unauthorized"]]
      end
    end
  end
end
