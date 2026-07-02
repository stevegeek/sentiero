# frozen_string_literal: true

require "concurrent-ruby"
require "securerandom"

module Sentiero
  module Stores
    class Memory < Store
      SessionMeta = Data.define(:created_at, :updated_at, :first_event_at, :last_event_at, :session_metadata)
      SessionEntry = Data.define(:meta, :windows)

      def initialize(limits: nil)
        @limits = limits
        @sessions = Concurrent::Map.new
        @problems = Concurrent::Map.new # fingerprint => problem Hash (symbol-keyed)
        @occurrences = Concurrent::Map.new # fingerprint => Concurrent::Array of occurrence Hashes
        @server_events = Concurrent::Array.new
      end

      def save_events(ref, events)
        validate_window_ref!(ref)
        session_id = ref.session_id
        window_id = ref.window_id

        return if events.nil? || events.empty?

        now = Time.now.to_f

        event_timestamps = events.filter_map { |event| event["timestamp"]&.to_f }
        batch_min = event_timestamps.min
        batch_max = event_timestamps.max

        @sessions.compute(session_id) do |existing|
          entry = if existing
            event_list = existing.windows.compute_if_absent(window_id) { Concurrent::Array.new }
            event_list.concat(events)

            new_first = batch_min ? [existing.meta.first_event_at, batch_min].compact.min : existing.meta.first_event_at
            new_last = batch_max ? [existing.meta.last_event_at, batch_max].compact.max : existing.meta.last_event_at

            SessionEntry.new(
              meta: existing.meta.with(updated_at: now, first_event_at: new_first, last_event_at: new_last),
              windows: existing.windows
            )
          else
            windows = Concurrent::Map.new
            event_list = Concurrent::Array.new
            event_list.concat(events)
            windows[window_id] = event_list

            SessionEntry.new(
              meta: SessionMeta.new(created_at: now, updated_at: now, first_event_at: batch_min, last_event_at: batch_max, session_metadata: nil),
              windows: windows
            )
          end

          trim_events!(entry)

          entry
        end

        enforce_max_sessions

        nil
      end

      def list_sessions(limit:, offset: 0, since: nil, until_time: nil, sort_by: nil, search: nil)
        pairs = @sessions.each_pair.to_a
        pairs = filter_sessions(pairs, since: since, until_time: until_time, search: search)
        pairs = sort_sessions(pairs, sort_by)
        page = pairs.slice(offset, limit) || []
        page.map { |sid, entry| session_summary(sid, entry) }
      end

      def get_session(session_id)
        validate_id!(session_id)
        entry = @sessions[session_id]
        return nil unless entry

        window_data = entry.windows.each_pair.map { |wid, events|
          timestamps = events.filter_map { |event| event[:timestamp] || event["timestamp"] }
          window = {window_id: wid, event_count: events.size}
          window[:first_event_at] = timestamps.min if timestamps.any?
          window[:last_event_at] = timestamps.max if timestamps.any?
          window
        }

        result = {
          session_id: session_id,
          windows: window_data,
          created_at: entry.meta.created_at,
          updated_at: entry.meta.updated_at,
          first_event_at: entry.meta.first_event_at,
          last_event_at: entry.meta.last_event_at
        }
        result[:metadata] = entry.meta.session_metadata if entry.meta.session_metadata
        result
      end

      def get_events(ref, after: nil, limit: nil)
        validate_window_ref!(ref)
        session_id = ref.session_id
        window_id = ref.window_id
        entry = @sessions[session_id]
        return [] unless entry

        events = entry.windows[window_id]
        return [] unless events

        result = events.to_a.sort_by { |event| event["timestamp"].to_f }

        if after
          idx = result.index { |event| event["timestamp"].to_f > after.to_f }
          result = idx ? result[idx..] : []
        end

        limit ? result.first(limit) : result
      end

      def save_metadata(session_id, metadata)
        validate_id!(session_id)
        return unless metadata.is_a?(Hash) && !metadata.empty?

        validate_metadata!(metadata)

        @sessions.compute(session_id) do |existing|
          next existing unless existing
          merged = (existing.meta.session_metadata || {}).merge(metadata)
          SessionEntry.new(meta: existing.meta.with(session_metadata: merged), windows: existing.windows)
        end
        nil
      end

      def delete_session(session_id)
        validate_id!(session_id)
        @sessions.delete(session_id)

        @occurrences.each_pair do |fp, list|
          list.reject! { |occ| occ["session_id"] == session_id }
        end
        @server_events.reject! { |event| event["session_id"] == session_id }

        nil
      end

      def delete_window(ref)
        validate_window_ref!(ref)
        session_id = ref.session_id
        window_id = ref.window_id
        @sessions.compute(session_id) do |existing|
          next nil unless existing

          existing.windows.delete(window_id)

          if existing.windows.empty?
            nil
          else
            existing
          end
        end
        nil
      end

      def save_occurrence(occurrence)
        validate_occurrence!(occurrence)
        fp = occurrence["fingerprint"]
        ts = occurrence["timestamp"].to_f

        stored = occurrence.merge("id" => SecureRandom.uuid)
        @occurrences.compute_if_absent(fp) { Concurrent::Array.new } << stored

        @problems.compute(fp) do |existing|
          existing ? touched_problem_attrs(existing, occurrence, ts) : new_problem_attrs(occurrence, ts)
        end

        enforce_max_problems
        save_metadata(occurrence["session_id"], {"has_errors" => true}) if occurrence["session_id"]
        fp
      end

      def list_problems(project:, limit:, offset: 0, status: nil, sort_by: nil, search: nil, since: nil, until_time: nil)
        filter_and_page_problems(@problems.values, project: project, status: status,
          since: since, until_time: until_time, search: search,
          sort_by: sort_by, offset: offset, limit: limit)
      end

      def get_problem(problem_id)
        validate_id!(problem_id)
        @problems[problem_id]&.dup
      end

      def get_occurrences(problem_id, after: nil, limit: nil)
        validate_id!(problem_id)
        list = @occurrences[problem_id]
        return [] unless list

        result = list.to_a.sort_by { |occ| occ["timestamp"].to_f }
        result = result.select { |occ| occ["timestamp"].to_f > after.to_f } if after
        limit ? result.first(limit) : result
      end

      # Override: count without sorting or duplicating the rows.
      def count_occurrences(problem_id, after: nil)
        validate_id!(problem_id)
        list = @occurrences[problem_id]
        return 0 unless list
        return list.size unless after

        after_f = after.to_f
        list.to_a.count { |occ| occ["timestamp"].to_f > after_f }
      end

      def update_problem_status(problem_id, status)
        validate_id!(problem_id)
        validate_status!(status)
        @problems.compute(problem_id) do |existing|
          next nil unless existing

          existing.merge(
            status: status,
            resolved_at: (status == "resolved") ? Time.now.to_f : nil
          )
        end
        nil
      end

      def save_server_event(event)
        validate_server_event!(event)
        @server_events << event.merge("id" => SecureRandom.uuid)
        enforce_max_server_events
        nil
      end

      def get_server_event(event_id)
        validate_id!(event_id)
        @server_events.find { |e| e["id"] == event_id }&.dup
      end

      def list_server_events(project:, limit:, name: nil, level: nil, session_id: nil, after: nil)
        filter_server_events(@server_events.to_a, project: project, name: name, level: level, session_id: session_id, after: after, limit: limit)
      end

      def occurrences_for_session(session_id, limit: nil)
        validate_id!(session_id)
        rows_for_session(@occurrences.values.flat_map(&:to_a), session_id, limit: limit)
      end

      def server_events_for_session(session_id, limit: nil)
        validate_id!(session_id)
        rows_for_session(@server_events.to_a, session_id, limit: limit)
      end

      def session_ids_for_problem(problem_id, limit: nil)
        validate_id!(problem_id)
        list = @occurrences[problem_id]
        return [] unless list

        latest_session_ids(list.to_a, limit: limit)
      end

      def purge_older_than(seconds)
        deleted = super
        purge_error_collections!(@problems, @occurrences, @server_events, Time.now.to_f - seconds)
        deleted
      end

      def clear!
        @sessions.clear
        @problems.clear
        @occurrences.clear
        @server_events.clear
        nil
      end

      private

      def filter_sessions(pairs, since:, until_time:, search:)
        if since
          since_f = since.to_f
          pairs = pairs.select { |_sid, entry| entry.meta.updated_at >= since_f }
        end
        if until_time
          until_f = until_time.to_f
          pairs = pairs.select { |_sid, entry| entry.meta.updated_at <= until_f }
        end
        if search && !search.empty?
          search_down = search.downcase
          pairs = pairs.select { |sid, entry|
            sid.downcase.include?(search_down) ||
              entry.meta.session_metadata&.values&.any? { |value| value.to_s.downcase.include?(search_down) }
          }
        end
        pairs
      end

      def sort_sessions(pairs, sort_by)
        case sort_by
        when "created_at"
          pairs.sort_by { |_sid, entry| -entry.meta.created_at }
        when "event_count"
          pairs.sort_by { |_sid, entry| -entry.windows.values.sum(&:size) }
        else
          pairs.sort_by { |_sid, entry| -entry.meta.updated_at }
        end
      end

      def session_summary(sid, entry)
        summary_hash(
          session_id: sid,
          window_ids: entry.windows.keys,
          event_count: entry.windows.values.sum(&:size),
          created_at: entry.meta.created_at,
          updated_at: entry.meta.updated_at,
          first_event_at: entry.meta.first_event_at,
          last_event_at: entry.meta.last_event_at,
          metadata: entry.meta.session_metadata
        )
      end

      def trim_events!(entry)
        max_events = limits.max_events_per_session
        return unless max_events

        total = entry.windows.values.sum(&:size)
        return unless total > max_events

        excess = total - max_events
        sorted_windows = entry.windows.each_pair.sort_by { |_wid, events|
          events.first&.fetch("timestamp", 0) || 0
        }
        sorted_windows.each do |_wid, events|
          break if excess <= 0

          drop = [excess, events.size].min
          events.shift(drop)
          excess -= drop
        end
      end

      def enforce_max_sessions
        max_sessions = limits.max_sessions
        return unless max_sessions && @sessions.size > max_sessions

        sorted = @sessions.each_pair.sort_by { |_sid, entry| entry.meta.updated_at }
        to_evict = @sessions.size - max_sessions
        sorted.first(to_evict).each { |sid, _entry| @sessions.delete(sid) }
      end

      def enforce_max_problems
        evict_oldest_problems!(@problems, @occurrences, limits.max_problems)
      end

      def enforce_max_server_events
        max = limits.max_server_events
        return unless max && @server_events.size > max

        excess = @server_events.size - max
        @server_events.shift(excess)
      end
    end
  end
end
