# frozen_string_literal: true

module Sentiero
  class Store
    # The session-replay store contract: recording windows of
    # rrweb events and reading them back as sessions.
    #
    # Window-level methods take a Sentiero::WindowRef; session-level methods
    # take a bare session_id.
    module SessionStore
      def save_events(ref, events)
        raise NoMethodError, "#{self.class}#save_events not implemented"
      end

      def list_sessions(limit:, offset: 0, since: nil, until_time: nil, sort_by: nil, search: nil)
        raise NoMethodError, "#{self.class}#list_sessions not implemented"
      end

      def get_session(session_id)
        raise NoMethodError, "#{self.class}#get_session not implemented"
      end

      def get_events(ref, after: nil, limit: nil)
        raise NoMethodError, "#{self.class}#get_events not implemented"
      end

      def delete_session(session_id)
        raise NoMethodError, "#{self.class}#delete_session not implemented"
      end

      def delete_window(ref)
        raise NoMethodError, "#{self.class}#delete_window not implemented"
      end

      # Optional; default is a no-op so custom stores keep working without it.
      def save_metadata(session_id, metadata)
        nil
      end

      # Yields [session_summary_hash, window_id, events_array] per window, newest
      # sessions first, capped at `limit`. Built from list_sessions/get_session/
      # get_events so every backend gets it free; stores may override.
      def each_session_events(limit: nil, since: nil, until_time: nil)
        return enum_for(:each_session_events, limit: limit, since: since, until_time: until_time) unless block_given?

        cap = limit || limits.analytics_max_scan_sessions
        sessions = list_sessions(limit: cap, since: since, until_time: until_time)

        sessions.each do |summary|
          session = get_session(summary[:session_id])
          next unless session

          windows = session[:windows] || []
          windows.each do |window|
            window_id = window[:window_id]
            events = get_events(WindowRef.new(summary[:session_id], window_id))
            yield summary, window_id, events
          end
        end
      end

      # Deletes every session whose updated_at is older than `seconds` ago,
      # returning the count. Built from list_sessions + delete_session so every
      # backend gets it free; stores may override with a direct query.
      #
      # list_sessions is newest-first, so stale sessions are the last ones
      # reached: we page through the whole store by advancing an offset (not just
      # re-reading the first batch) and delete only after the full scan, so
      # deletions don't shift the pages we're still walking.
      def purge_older_than(seconds)
        cutoff = Time.now.to_f - seconds
        batch_size = limits.analytics_max_scan_sessions
        stale = []
        offset = 0

        loop do
          summaries = list_sessions(limit: batch_size, offset: offset)
          break if summaries.empty?

          stale.concat(
            summaries
              .select { |summary| summary[:updated_at] < cutoff }
              .map { |summary| summary[:session_id] }
          )
          break if summaries.size < batch_size

          offset += batch_size
        end

        stale.each { |session_id| delete_session(session_id) }
        stale.size
      end

      private

      # The session-summary shape returned by list_sessions/each_session_events,
      # shared by every backend so the seven near-identical hash literals stay
      # in exact lockstep. metadata is included only when present and non-empty,
      # matching how each backend already treats "no metadata" as "no key".
      def summary_hash(session_id:, window_ids:, event_count:, created_at:, updated_at:,
        first_event_at: nil, last_event_at: nil, metadata: nil)
        entry = {session_id: session_id, window_ids: window_ids, event_count: event_count,
                 created_at: created_at, updated_at: updated_at,
                 first_event_at: first_event_at, last_event_at: last_event_at}
        entry[:metadata] = metadata if metadata && !metadata.empty?
        entry
      end

      # True when the search term (case-insensitive) appears in the session_id
      # or any metadata value.
      def session_matches_search?(summary, search)
        search_down = search.downcase
        summary[:session_id].downcase.include?(search_down) ||
          summary[:metadata]&.values&.any? { |value| value.to_s.downcase.include?(search_down) } || false
      end
    end
  end
end
