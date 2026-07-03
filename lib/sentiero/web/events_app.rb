# frozen_string_literal: true

require "json"
require "rack/utils"
require_relative "body_reader"
require_relative "../analytics/events"
require_relative "../redaction"
require_relative "../store"
require_relative "../geo"

module Sentiero
  module Web
    class EventsApp
      def call(env)
        method = env["REQUEST_METHOD"]

        case method
        when "POST"
          handle_post(env)
        when "OPTIONS"
          handle_options(env)
        else
          with_cors(env, [405, {"content-type" => "application/json"}, ['{"error":"method not allowed"}']])
        end
      end

      private

      def handle_post(env)
        # Drop the batch (silently, 204, same as the opt-out path so clients
        # treat it as success and don't retry) when the user opted out via
        # cookie, or sent Sec-GPC and the server is configured to honor it.
        # This backstops the client, which is expected to not even start
        # recording for GPC users, but a stale bundle or non-Sentiero caller
        # could still POST here.
        return dropped(env) if opted_out?(env) || gpc_signaled?(env)

        raw_body, error = BodyReader.read(env)
        if error
          status, message = BodyReader::ERRORS[error]
          return cors_error(env, status, message)
        end

        begin
          data = JSON.parse(raw_body)
        rescue JSON::ParserError
          return cors_error(env, 400, "invalid JSON body")
        end

        session_id = data["sessionId"]
        window_id = data["windowId"]
        events = data["events"]

        unless session_id.is_a?(String) && session_id.match?(Store::VALID_ID)
          return cors_error(env, 400, "sessionId must be 1-128 alphanumeric, hyphen, or underscore characters")
        end

        unless window_id.is_a?(String) && window_id.match?(Store::VALID_ID)
          return cors_error(env, 400, "windowId must be 1-128 alphanumeric, hyphen, or underscore characters")
        end

        unless events.is_a?(Array) && !events.empty? && events.all? { |e| e.is_a?(Hash) }
          return cors_error(env, 400, "events must be a non-empty array of objects")
        end

        max_per_request = Sentiero.configuration.max_events_per_request
        if max_per_request && events.size > max_per_request
          return cors_error(env, 400, "too many events (max #{max_per_request})")
        end

        events, error = normalize_timestamps(env, events)
        return error if error

        events = redact_events(events)

        Sentiero.store.save_events(Sentiero::WindowRef.new(session_id, window_id), events)

        # Save optional session metadata if present, plus a monotonic has_errors
        # flag computed from the incoming batch when error capture is enabled.
        metadata = data["metadata"]
        metadata = {} unless metadata.is_a?(Hash)

        if Sentiero.configuration.capture_errors && batch_has_errors?(events)
          metadata = metadata.merge("has_errors" => true)
        end

        # Merged underneath the client's keys so a page-set metadata value is never clobbered.
        metadata = Sentiero::Geo.resolve(env, Sentiero.configuration.geo_source).merge(metadata)

        unless metadata.empty?
          metadata = Sentiero::Redaction.redact_metadata(metadata, Sentiero.configuration.redaction)
          Sentiero.store.save_metadata(session_id, metadata)
        end

        with_cors(env, [200, {"content-type" => "application/json"}, ['{"status":"ok"}']])
      end

      def normalize_timestamps(env, events)
        events.each do |event|
          next unless event.key?("timestamp")

          raw = event["timestamp"]
          begin
            ts = raw.is_a?(Numeric) ? raw.to_f : Float(raw)
          rescue ArgumentError, TypeError
            return [nil, cors_error(env, 400, "invalid timestamp value")]
          end
          return [nil, cors_error(env, 400, "invalid timestamp value")] unless ts.finite?

          event["timestamp"] = ts
        end

        [events, nil]
      end

      # Field-aware redaction (defense-in-depth; the client already redacts) plus
      # the optional Ruby-only server_proc. A raising or nil/false server_proc
      # drops the event (we never store unsanitized data).
      def redact_events(events)
        config = Sentiero.configuration.redaction
        proc = config.server_proc

        events.filter_map do |event|
          redacted = Sentiero::Redaction.redact_event(event, config)
          next redacted unless proc.respond_to?(:call)

          begin
            proc.call(redacted)
          rescue => e
            warn "[Sentiero] redaction server_proc raised #{e.class}: #{e.message}; dropping event"
            nil
          end
        end
      end

      def opted_out?(env)
        config = Sentiero.configuration
        return false unless config.user_opt_out

        cookies = Rack::Utils.parse_cookies(env)
        value = cookies[config.opt_out_cookie_name]
        !value.nil? && !value.empty? && value != "0" && value != "false"
      end

      def gpc_signaled?(env)
        Sentiero.configuration.respect_gpc && env["HTTP_SEC_GPC"] == "1"
      end

      def dropped(env)
        with_cors(env, [204, {"content-type" => "application/json"}, []])
      end

      # rrweb custom events arrive as { type: 5, data: { tag, payload } }; the
      # recorder tags error events "error", so a batch "has errors" when any
      # custom event carries that tag.
      def batch_has_errors?(events)
        events.any? do |event|
          event["type"] == Sentiero::Analytics::Events::CUSTOM &&
            event["data"].is_a?(Hash) && event["data"]["tag"] == "error"
        end
      end

      def handle_options(env)
        headers = {
          "access-control-allow-methods" => "POST",
          "access-control-allow-headers" => "Content-Type, Content-Encoding",
          "access-control-max-age" => "86400",
          "content-type" => "text/plain"
        }

        with_cors(env, [204, headers, []])
      end

      def with_cors(env, response)
        status, headers, body = response
        headers["x-content-type-options"] = "nosniff"
        origins = Sentiero.configuration.cors_origins

        if origins && !origins.empty?
          request_origin = env["HTTP_ORIGIN"]

          if request_origin && origins.include?(request_origin)
            headers["access-control-allow-origin"] = request_origin
            headers["vary"] = "Origin"
          end
        end

        [status, headers, body]
      end

      def cors_error(env, status, message)
        with_cors(env, [status, {"content-type" => "application/json"}, [json_error(message)]])
      end

      def json_error(message)
        JSON.generate({error: message})
      end
    end
  end
end
