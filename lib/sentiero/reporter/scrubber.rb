# frozen_string_literal: true

require_relative "../redaction"

module Sentiero
  module Reporter
    # Replaces values whose key matches a sensitive pattern with "[FILTERED]",
    # before data leaves the host app, so secrets never traverse the network.
    # Matching is case-insensitive and substring based ("user_password" matches "password").
    class Scrubber
      FILTERED = "[FILTERED]"
      # Superset of Redaction::BUILTIN_DENYLIST (the browser-lane URL param
      # denylist) plus a few extras (credit card/SSN) the query-string lane
      # doesn't need to cover. Keeping this as a union rather than a hand
      # copy means the two lanes can't drift apart again.
      DEFAULT_KEYS = (%w[
        password passwd secret token api_key apikey authorization
        access_token refresh_token secret_key private_key
        credit_card card_number cvv ssn
      ] + Redaction::BUILTIN_DENYLIST).uniq.freeze

      def initialize(keys = DEFAULT_KEYS)
        @patterns = Array(keys).map { |k| k.to_s.downcase }
      end

      def scrub(obj)
        case obj
        when Hash
          obj.each_with_object(obj.class.new) do |(k, v), acc|
            acc[k] = sensitive?(k) ? FILTERED : scrub(v)
          end
        when Array
          obj.map { |v| scrub(v) }
        else
          obj
        end
      end

      private

      def sensitive?(key)
        down = key.to_s.downcase
        @patterns.any? { |pattern| down.include?(pattern) }
      end
    end
  end
end
