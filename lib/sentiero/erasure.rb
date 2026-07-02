# frozen_string_literal: true

module Sentiero
  # Right-to-erasure helpers (GDPR Art. 17). Store-agnostic.
  # Erasure is destructive and irreversible; deleted sessions cannot be recovered.
  module Erasure
    module_function

    def erase_sessions(store, ids)
      ids.each do |id|
        raise ArgumentError, "Invalid ID: #{id.inspect}" unless Store::VALID_ID.match?(id.to_s)
      end
      present = ids.select { |id| store.get_session(id) }
      present.each { |id| store.delete_session(id) }
      present.size
    end

    # At least one bound is required to guard against erasing everything; the
    # range is inclusive. Lists/deletes in capped batches (paging) until a scan
    # is short, so one call erases every match regardless of count.
    def erase_where(store, since: nil, until_time: nil)
      raise ArgumentError, "provide since: and/or until_time:" if since.nil? && until_time.nil?
      if since && until_time && since.to_f > until_time.to_f
        raise ArgumentError, "since: must not be after until_time:"
      end

      cap = store.limits.analytics_max_scan_sessions
      erased = 0

      loop do
        ids = store.list_sessions(
          limit: cap,
          since: since,
          until_time: until_time
        ).map { |summary| summary[:session_id] }

        ids.each { |id| store.delete_session(id) }
        erased += ids.size

        # Each listed session matched and was deleted, so the set shrinks;
        # a short batch means the matches are exhausted.
        break if ids.size < cap
      end

      erased
    end
  end
end
