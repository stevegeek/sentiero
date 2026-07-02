# frozen_string_literal: true

module Sentiero
  module Reporter
    # Splits a Context into the reserved keys that become top-level fields on an
    # error report (session_id, window_id) and the remaining metadata that goes
    # under the report's "context".
    class ReportContext
      RESERVED = %w[session_id window_id].freeze

      def initialize(context)
        data = context.to_h
        @reserved = {}
        RESERVED.each do |key|
          value = data.delete(key)
          @reserved[key] = value unless value.nil?
        end
        @metadata = data
      end

      def session_id = @reserved["session_id"]

      def window_id = @reserved["window_id"]

      # Mutable so the caller can inject environment/release before scrubbing.
      attr_reader :metadata
    end
  end
end
