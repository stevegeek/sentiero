# frozen_string_literal: true

module Sentiero
  module Analytics
    # Cap primitives shared by the compute-on-read collectors/analyzers, which
    # bound memory during a scan. Both leave the collection unchanged once full,
    # so the caller flips its own `@capped` flag on a false/nil return.
    module Bounded
      # Counter cap: bump counts[key] (a Hash defaulting to 0), adding a NEW key
      # only while under `cap` (nil = unbounded). Returns true if counted, false
      # if the cap dropped it.
      def bounded_increment(counts, key, cap, by: 1)
        return false unless counts.key?(key) || cap.nil? || counts.size < cap

        counts[key] += by
        true
      end

      # Slot cap: the existing entry, a freshly built one (yielded, while under
      # `cap`), or nil when the store already holds `cap` distinct keys.
      def bounded_fetch(store, key, cap)
        return store[key] if store.key?(key)
        return nil if cap && store.size >= cap

        store[key] = yield
      end
    end
  end
end
