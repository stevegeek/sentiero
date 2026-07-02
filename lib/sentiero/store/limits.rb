# frozen_string_literal: true

module Sentiero
  class Store
    # Eviction/scan caps for a store, held by the store itself instead of read
    # from the global Sentiero.configuration. Build one explicitly, or derive the
    # configured defaults at the composition root with .from_configuration.
    class Limits
      DEFAULTS = {
        max_events_per_session: nil,
        max_sessions: nil,
        max_problems: 5_000,
        max_server_events: 50_000,
        analytics_max_scan_sessions: 5_000
      }.freeze

      def self.from_configuration(config = Sentiero.configuration)
        new(**DEFAULTS.keys.to_h { |attr| [attr, config.public_send(attr)] })
      end

      attr_reader(*DEFAULTS.keys)

      def initialize(**overrides)
        unknown = overrides.keys - DEFAULTS.keys
        raise ArgumentError, "unknown limit(s): #{unknown.join(", ")}" unless unknown.empty?

        DEFAULTS.merge(overrides).each { |attr, value| instance_variable_set(:"@#{attr}", value) }
      end
    end
  end
end
