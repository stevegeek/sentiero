# frozen_string_literal: true

module Sentiero
  module Redaction
    # Operator-facing redaction settings. The declarative subset serializes to
    # the client (to_client_hash) and drives both engines; dom_patterns and
    # server_proc are server-only.
    class Config
      attr_accessor :server_proc
      attr_reader :url_mode, :disabled_patterns, :custom_patterns, :dom_patterns

      URL_MODE_TO_CLIENT = {strip: "strip", keep_all: "keepAll", keep_filtered: "keepFiltered"}.freeze
      URL_MODE_FROM_CLIENT = URL_MODE_TO_CLIENT.invert.freeze

      def self.from_client_hash(hash)
        hash ||= {}
        new(
          url_mode: URL_MODE_FROM_CLIENT.fetch(hash["urlMode"], :strip),
          url_param_allowlist: hash["urlParamAllowlist"] || [],
          url_param_denylist: hash["urlParamDenylist"] || [],
          disabled_patterns: (hash["disabledPatterns"] || []).map(&:to_sym),
          custom_patterns: (hash["customPatterns"] || []).map { |s| Regexp.new(s) }
        )
      end

      def initialize(url_mode: :strip, url_param_allowlist: [], url_param_denylist: [], disabled_patterns: [], custom_patterns: [], dom_patterns: [], server_proc: nil)
        @url_mode = url_mode
        @url_param_allowlist = url_param_allowlist
        @url_param_denylist = url_param_denylist
        @disabled_patterns = disabled_patterns
        @custom_patterns = custom_patterns
        # Symbols so `TEXT_PATTERN_ORDER - dom_patterns` in redact_dom_event works
        # even when an operator passes pattern names as strings.
        @dom_patterns = dom_patterns.map(&:to_sym)
        @server_proc = server_proc
      end

      def active_text_patterns
        TEXT_PATTERN_ORDER - disabled_patterns
      end

      def effective_allowlist
        @url_param_allowlist.map(&:downcase)
      end

      def effective_denylist
        (BUILTIN_DENYLIST + @url_param_denylist.map(&:downcase)).uniq
      end

      def to_client_hash
        {
          urlMode: URL_MODE_TO_CLIENT.fetch(url_mode, "strip"),
          urlParamAllowlist: effective_allowlist,
          urlParamDenylist: effective_denylist,
          disabledPatterns: disabled_patterns.map(&:to_s),
          customPatterns: custom_patterns.map(&:source)
        }
      end
    end
  end
end
