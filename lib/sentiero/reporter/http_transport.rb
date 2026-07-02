# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Sentiero
  module Reporter
    # Posts a JSON payload to "<endpoint>/<path>" with the ingest key as a Bearer token.
    class HttpTransport
      LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

      def initialize(endpoint:, ingest_key:, open_timeout:, read_timeout:)
        @endpoint = endpoint.to_s.sub(%r{/+\z}, "")
        @ingest_key = ingest_key
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        warn_insecure_endpoint
      end

      def post(path, payload)
        uri = URI.parse("#{@endpoint}/#{path}")
        http = build_http(uri)

        request = Net::HTTP::Post.new(uri)
        request["content-type"] = "application/json"
        request["authorization"] = "Bearer #{@ingest_key}"
        request.body = JSON.generate(payload)

        http.request(request)
      end

      private

      def build_http(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        http
      end

      # The Bearer ingest key and payloads go in cleartext over http://; warn
      # unless the endpoint is loopback (a common local-dev setup).
      def warn_insecure_endpoint
        uri = URI.parse(@endpoint)
        return unless uri.scheme == "http"
        return if LOOPBACK_HOSTS.include?(uri.host)

        warn "[Sentiero::Reporter] endpoint #{@endpoint} uses http://; the ingest " \
          "key and payloads are sent unencrypted. Use https://."
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end
