# frozen_string_literal: true

require_relative "ingest_app"
require_relative "../fingerprint"
require_relative "../redaction"
require_relative "../ip_anonymizer"

module Sentiero
  module Web
    # Server-lane ingest for exceptions. Computes the grouping fingerprint
    # server-side, then persists via Sentiero.store.save_occurrence.
    class ErrorsApp < IngestApp
      MAX_BACKTRACE_FRAMES = 100
      MAX_MESSAGE_LENGTH = 4000
      MAX_CONTEXT_BYTES = 16_384
      PLATFORM_PATTERN = /\A[a-z0-9_-]{1,32}\z/i

      private

      def handle(env, project, data)
        exception_class = data["exception_class"]
        message = data["message"]

        unless exception_class.is_a?(String) && !exception_class.empty?
          return json_response(400, {error: "exception_class is required"})
        end
        unless message.is_a?(String) && !message.empty?
          return json_response(400, {error: "message is required"})
        end

        session_id = data["session_id"]
        window_id = data["window_id"]
        if session_id && !valid_optional_id?(session_id)
          return json_response(400, {error: "invalid session_id"})
        end
        if window_id && !valid_optional_id?(window_id)
          return json_response(400, {error: "invalid window_id"})
        end

        backtrace = data["backtrace"]
        backtrace = backtrace.is_a?(Array) ? backtrace.first(MAX_BACKTRACE_FRAMES).map(&:to_s) : nil

        # Redact before fingerprinting so grouping is stable whether or not the
        # client already redacted.
        redaction = Sentiero.configuration.redaction
        message = Redaction.redact_text(message, redaction)
        backtrace &&= backtrace.map { |frame| Redaction.redact_text(frame, redaction) }

        timestamp = numeric_timestamp(data["timestamp"])
        platform = valid_platform(data["platform"])
        normalizer = Sentiero.configuration.fingerprint.resolve(platform)

        fingerprint = Fingerprint.compute(
          exception_class: exception_class,
          backtrace: backtrace,
          project: project,
          normalizer: normalizer
        )

        occurrence = {
          "fingerprint" => fingerprint,
          "project" => project,
          "exception_class" => exception_class,
          "message" => message[0, MAX_MESSAGE_LENGTH],
          "timestamp" => timestamp
        }
        occurrence["backtrace"] = backtrace if backtrace
        if data["context"].is_a?(Hash)
          context = Redaction.deep_redact_strings(capped_context(data["context"]), redaction)
          occurrence["context"] = anonymize_request_ip(context)
        end
        occurrence["session_id"] = session_id if session_id
        occurrence["window_id"] = window_id if window_id
        occurrence["platform"] = platform if platform

        begin
          Sentiero.store.save_occurrence(occurrence)
        rescue ArgumentError => e
          return json_response(400, {error: e.message})
        end

        json_response(200, {status: "ok", fingerprint: fingerprint})
      end

      # Anything not matching PLATFORM_PATTERN is treated as absent (tier 1:
      # default_platform's normalizer), not rejected — an unrecognized tag is a
      # reporter quirk, not a malformed request. Downcased so storage/resolve
      # use one canonical form.
      def valid_platform(raw)
        (raw.is_a?(String) && PLATFORM_PATTERN.match?(raw)) ? raw.downcase : nil
      end

      def capped_context(context)
        (JSON.generate(context).bytesize <= MAX_CONTEXT_BYTES) ? context : {"_truncated" => true}
      end

      # Backstop for reporters that don't (or can't) honor anonymize_ip
      # themselves: mirrors Reporter::Middleware#client_ip's truncation so a
      # server configured with anonymize_ip: true never persists a raw IP.
      def anonymize_request_ip(context)
        return context unless Sentiero.configuration.anonymize_ip

        request = context["request"]
        return context unless request.is_a?(Hash) && request["ip"].is_a?(String)

        context.merge("request" => request.merge("ip" => IpAnonymizer.anonymize(request["ip"])))
      end
    end
  end
end
