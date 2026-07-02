# frozen_string_literal: true

require "digest"

module Sentiero
  # Computes the grouping fingerprint for an exception occurrence. The
  # normalization regexes are deliberately linear-time (simple character classes
  # with a single quantifier, no nesting) so untrusted backtraces cannot trigger
  # catastrophic backtracking (ReDoS).
  module Fingerprint
    # Only the top frames drive grouping (deeper frames vary by call site).
    MAX_FRAMES = 5
    MAX_FRAME_LENGTH = 1000

    module_function

    def compute(exception_class:, backtrace:, project:)
      frames = Array(backtrace).first(MAX_FRAMES).map { |frame| normalize_frame(frame.to_s) }
      input = "#{project}\n#{exception_class}\n#{frames.join("\n")}"
      Digest::SHA256.hexdigest(input)[0, 40]
    end

    # Strips per-occurrence noise (memory addresses, line numbers). Digits inside
    # identifiers (e.g. `step_1`, `V2::Api`) are preserved so distinct methods do
    # not collapse into one group.
    def normalize_frame(frame)
      frame = frame[0, MAX_FRAME_LENGTH].strip
      frame
        .gsub(/0x[0-9a-fA-F]+/, "0xHEX") # memory addresses
        .gsub(/:[0-9]+(?=:in )/, ":N") # `path:LINE:in 'method'`
        .gsub(/:[0-9]+\z/, ":N") # `path:LINE` (top-level frame, no method)
    end
  end
end
