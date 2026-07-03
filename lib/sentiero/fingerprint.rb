# frozen_string_literal: true

require "digest"
require_relative "fingerprint/config"

module Sentiero
  # Computes the grouping fingerprint for an exception occurrence. The
  # normalization regexes are deliberately linear-time (simple character classes
  # with a single quantifier, no nesting) so untrusted backtraces cannot trigger
  # catastrophic backtracking (ReDoS).
  module Fingerprint
    # Only the top frames drive grouping (deeper frames vary by call site).
    MAX_FRAMES = 5
    MAX_FRAME_LENGTH = 1000

    # `path:LINE:in 'method'` (colon-glued) or bare `path:LINE`. Verbatim
    # pre-refactor logic, kept byte-identical so upgrading does not fracture
    # existing problem groups — this is the tier-1 (no platform tag) default.
    RUBY_NORMALIZER = ->(frame) {
      frame
        .gsub(/0x[0-9a-fA-F]+/, "0xHEX") # memory addresses
        .gsub(/:[0-9]+(?=:in )/, ":N") # `path:LINE:in 'method'`
        .gsub(/:[0-9]+\z/, ":N") # `path:LINE` (top-level frame, no method)
    }

    # `path.cr:LINE in 'method'` or `path.cr:LINE:COL in 'method'` — Crystal
    # separates the line marker from `in` with a space, not a colon, and may
    # carry an optional `:column`, so the Ruby regex is a no-op on it.
    CRYSTAL_NORMALIZER = ->(frame) {
      frame
        .gsub(/0x[0-9a-fA-F]+/, "0xHEX")
        .gsub(/:[0-9]+(?::[0-9]+)?(?= in )/, ":N")
    }

    # Grammar-agnostic fallback: strips a trailing `:LINE` or `:LINE:COL` only,
    # with no `in`-token assumption. Coarser than a language-specific
    # normalizer (it can't see line noise that isn't at the end of the frame)
    # but never mis-applies a foreign grammar.
    GENERIC_NORMALIZER = ->(frame) {
      frame
        .gsub(/0x[0-9a-fA-F]+/, "0xHEX")
        .gsub(/:[0-9]+(?::[0-9]+)?\z/, ":N")
    }

    module_function

    def compute(exception_class:, backtrace:, project:, normalizer: RUBY_NORMALIZER)
      frames = Array(backtrace).first(MAX_FRAMES).map { |frame| safe_normalize(normalizer, frame.to_s) }
      input = "#{project}\n#{exception_class}\n#{frames.join("\n")}"
      Digest::SHA256.hexdigest(input)[0, 40]
    end

    # Internal helper, not part of the public API. Wraps a (possibly
    # user-registered) normalizer so a broken or pathological callable can
    # never break fingerprinting: the frame is capped before and after
    # normalization, and any exception falls back to the raw capped frame.
    def safe_normalize(normalizer, frame)
      capped = frame[0, MAX_FRAME_LENGTH].strip
      normalizer.call(capped).to_s[0, MAX_FRAME_LENGTH]
    rescue
      capped
    end
  end
end
