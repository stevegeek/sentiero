# frozen_string_literal: true

require "rack/utils"
require_relative "../reporter"
require_relative "../ip_anonymizer"

module Sentiero
  module Reporter
    # Rack middleware that reports unhandled exceptions to Sentiero and re-raises
    # them so the host app's own error handling is unaffected. Reads the recorder's
    # session/window id cookies into the context so server exceptions link to the replay.
    class Middleware
      def initialize(app)
        @app = app
      end

      def call(env)
        Reporter.with_context(request_context(env)) do
          @app.call(env)
        rescue => e
          Reporter.notify(e)
          raise
        end
      end

      private

      def request_context(env)
        cookies = Rack::Utils.parse_cookies(env)
        ctx = {
          request: {
            "method" => env["REQUEST_METHOD"],
            "path" => env["PATH_INFO"],
            "params" => safe_parse_query(env["QUERY_STRING"]),
            "ip" => client_ip(env)
          }
        }
        sid = cookies[Reporter.configuration.session_cookie_name]
        wid = cookies[Reporter.configuration.window_cookie_name]
        ctx[:session_id] = sid if sid && !sid.empty?
        ctx[:window_id] = wid if wid && !wid.empty?
        ctx
      rescue => e
        warn "[Sentiero::Reporter] request_context failed: #{e.class}: #{e.message}"
        {}
      end

      def safe_parse_query(query_string)
        Rack::Utils.parse_nested_query(query_string)
      rescue => _e
        {}
      end

      def client_ip(env)
        forwarded = env["HTTP_X_FORWARDED_FOR"]&.split(",")&.first&.strip
        ip = (forwarded && !forwarded.empty?) ? forwarded : env["REMOTE_ADDR"]
        anonymize = Sentiero.respond_to?(:configuration) && Sentiero.configuration.anonymize_ip
        anonymize ? IpAnonymizer.anonymize(ip) : ip
      end
    end
  end
end
