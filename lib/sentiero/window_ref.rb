# frozen_string_literal: true

module Sentiero
  # Addresses a single recording window by its (session_id, window_id) pair.
  WindowRef = Data.define(:session_id, :window_id)
end
