# frozen_string_literal: true

require_relative "ingest_app"
require_relative "../redaction"

module Sentiero
  module Web
    # Server-lane ingest for custom events (Sentiero.track). Flat, un-grouped;
    # persisted via Sentiero.store.save_server_event.
    class TrackApp < IngestApp
      VALID_LEVELS = %w[debug info warn error].freeze
      MAX_NAME_LENGTH = 200
      MAX_PAYLOAD_BYTES = 16_384

      private

      def handle(env, project, data)
        name = data["name"]
        unless name.is_a?(String) && !name.empty?
          return json_response(400, {error: "name is required"})
        end

        session_id = data["session_id"]
        if session_id && !valid_optional_id?(session_id)
          return json_response(400, {error: "invalid session_id"})
        end

        level = data["level"]
        level = "info" unless VALID_LEVELS.include?(level)

        event = {
          "project" => project,
          "name" => name[0, MAX_NAME_LENGTH],
          "level" => level,
          "timestamp" => numeric_timestamp(data["timestamp"])
        }
        if data["payload"].is_a?(Hash)
          redacted = Redaction.deep_redact_strings(capped_payload(data["payload"]), Sentiero.configuration.redaction)
          event["payload"] = redacted
        end
        event["session_id"] = session_id if session_id

        begin
          Sentiero.store.save_server_event(event)
        rescue ArgumentError => e
          return json_response(400, {error: e.message})
        end

        json_response(200, {status: "ok"})
      end

      def capped_payload(payload)
        (JSON.generate(payload).bytesize <= MAX_PAYLOAD_BYTES) ? payload : {"_truncated" => true}
      end
    end
  end
end
