# frozen_string_literal: true

require "json"
require "rack/utils"
require_relative "body_reader"
require_relative "../store"

module Sentiero
  module Web
    # Base class for the authenticated server-lane ingest apps (eg ErrorsApp, TrackApp).
    # Subclasses implement #handle(env, project, data).
    #
    # Unlike EventsApp (the public browser lane), these require a per-project
    # write-only ingest key: Authorization: Bearer <key>. Keys map to a project
    # via Sentiero.configuration.ingest_keys ({ "<secret>" => "<project>" }).
    class IngestApp
      def call(env)
        return json_response(405, {error: "method not allowed"}) unless env["REQUEST_METHOD"] == "POST"

        project = authenticate(env)
        return json_response(401, {error: "invalid or missing ingest key"}) unless project

        body, error = read_body(env)
        return error if error

        begin
          data = JSON.parse(body)
        rescue JSON::ParserError
          return json_response(400, {error: "invalid JSON body"})
        end
        return json_response(400, {error: "body must be a JSON object"}) unless data.is_a?(Hash)

        handle(env, project, data)
      end

      private

      # Subclass hook; returns a Rack response triple.
      def handle(env, project, data)
        raise NoMethodError, "#{self.class}#handle not implemented"
      end

      # Resolves the ingest key to a project name, or nil. Constant-time compare
      # so timing can't distinguish a wrong key from a right one of equal length.
      def authenticate(env)
        keys = Sentiero.configuration.ingest_keys
        return nil if keys.nil? || keys.empty?

        presented = bearer_token(env)
        return nil if presented.nil? || presented.empty?

        keys.each do |key, project|
          return project if Rack::Utils.secure_compare(key.to_s, presented)
        end
        nil
      end

      def bearer_token(env)
        header = env["HTTP_AUTHORIZATION"]
        return nil unless header

        scheme, token = header.split(" ", 2)
        return nil unless scheme&.downcase == "bearer"
        token&.strip
      end

      def read_body(env)
        raw, error = BodyReader.read(env)
        return [raw, nil] unless error

        status, message = BodyReader::ERRORS[error]
        [nil, json_response(status, {error: message})]
      end

      def json_response(status, hash)
        [status, {"content-type" => "application/json", "x-content-type-options" => "nosniff"}, [JSON.generate(hash)]]
      end

      def numeric_timestamp(raw)
        return Time.now.to_f if raw.nil?
        ts = raw.is_a?(Numeric) ? raw.to_f : Float(raw)
        ts.finite? ? ts : Time.now.to_f
      rescue ArgumentError, TypeError
        Time.now.to_f
      end

      def valid_optional_id?(id)
        id.is_a?(String) && id.match?(Store::VALID_ID)
      end
    end
  end
end
