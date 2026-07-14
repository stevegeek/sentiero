# frozen_string_literal: true

module Sentiero
  module Fingerprint
    # Registry of per-platform frame normalizers, reached as
    # `Sentiero.configuration.fingerprint`. `ErrorsApp` resolves an incoming
    # occurrence's optional "platform" tag against this registry to pick the
    # normalizer passed to Fingerprint.compute.
    class Config
      attr_accessor :default_platform

      def initialize
        @normalizers = {}
        @default_platform = "ruby"
        register("ruby", RUBY_NORMALIZER)
        register("crystal", CRYSTAL_NORMALIZER)
        register("generic", GENERIC_NORMALIZER)
      end

      # Registering an existing name overrides it, so operators may replace a
      # built-in (e.g. swap out "ruby") as well as add new platforms.
      def register(name, callable)
        @normalizers[name.to_s] = callable
      end

      # Three-tier resolution (see design doc): a reporter that never learned
      # about the "platform" field must keep grouping exactly as before
      # (absent/blank -> default_platform's normalizer, tier 1), whereas a
      # reporter that declares a platform we don't recognize should not have a
      # foreign grammar mis-applied to it (unregistered -> generic, tier 3).
      def resolve(platform)
        if platform.nil? || platform.to_s.strip.empty?
          @normalizers.fetch(default_platform.to_s, RUBY_NORMALIZER)
        else
          @normalizers.fetch(platform.to_s, GENERIC_NORMALIZER)
        end
      end
    end
  end
end
