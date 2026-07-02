# frozen_string_literal: true

module Sentiero
  class Store
    # The error-tracking store contract: problems, occurrences, and server events.
    #
    # Keying convention: raw stored records (occurrences, server events) are
    # string-keyed Hashes, exactly as they arrived from JSON; computed
    # summaries (problems) are symbol-keyed.
    module ErrorStore
      # Records the occurrence and upserts its Problem (keyed by "fingerprint"):
      # bump count, extend last_seen, preserve first_seen, refresh message,
      # reopen if "resolved". Returns the problem id (== fingerprint).
      def save_occurrence(occurrence)
        raise NoMethodError, "#{self.class}#save_occurrence not implemented"
      end

      # since/until_time (epoch seconds) bound the listing by each problem's
      # last_seen, inclusive on both ends.
      def list_problems(project:, limit:, offset: 0, status: nil, sort_by: nil, search: nil, since: nil, until_time: nil)
        raise NoMethodError, "#{self.class}#list_problems not implemented"
      end

      # Returns the symbol-keyed problem summary, or nil when unknown.
      def get_problem(problem_id)
        raise NoMethodError, "#{self.class}#get_problem not implemented"
      end

      # Returns string-keyed occurrence records as stored (plus assigned "id"),
      # ascending by timestamp; `after` is an exclusive timestamp cursor.
      def get_occurrences(problem_id, after: nil, limit: nil)
        raise NoMethodError, "#{self.class}#get_occurrences not implemented"
      end

      # Default materializes rows via get_occurrences so custom stores keep
      # working; built-in backends override with direct counts.
      def count_occurrences(problem_id, after: nil)
        get_occurrences(problem_id, after: after).size
      end

      def update_problem_status(problem_id, status)
        raise NoMethodError, "#{self.class}#update_problem_status not implemented"
      end

      def save_server_event(event)
        raise NoMethodError, "#{self.class}#save_server_event not implemented"
      end

      # Returns string-keyed server-event records as stored (plus assigned
      # "id"), ascending by timestamp; `after` is an exclusive timestamp cursor.
      def list_server_events(project:, limit:, name: nil, level: nil, session_id: nil, after: nil)
        raise NoMethodError, "#{self.class}#list_server_events not implemented"
      end

      def get_server_event(event_id)
        raise NoMethodError, "#{self.class}#get_server_event not implemented"
      end

      def occurrences_for_session(session_id, limit: nil)
        raise NoMethodError, "#{self.class}#occurrences_for_session not implemented"
      end

      def server_events_for_session(session_id, limit: nil)
        raise NoMethodError, "#{self.class}#server_events_for_session not implemented"
      end

      def session_ids_for_problem(problem_id, limit: nil)
        raise NoMethodError, "#{self.class}#session_ids_for_problem not implemented"
      end

      private

      # Shared problem bookkeeping: the semantic source of truth for problem
      # lifecycle rules, which SQLite and the Rails store re-express natively.

      # The list_problems filter/sort/paginate pipeline over symbol-keyed problem
      # hashes; since/until_time bounds on last_seen are inclusive. Returns dups
      # so callers can't mutate stored problems through the result.
      def filter_and_page_problems(items, project:, status:, since:, until_time:, search:, sort_by:, offset:, limit:)
        items = items.select { |p| p[:project] == project } unless project.nil?
        items = items.select { |p| p[:status] == status } if status
        items = items.select { |p| p[:last_seen] >= since.to_f } if since
        items = items.select { |p| p[:last_seen] <= until_time.to_f } if until_time
        if search && !search.empty?
          term = search.downcase
          items = items.select { |p|
            p[:title].downcase.include?(term) || p[:exception_class].downcase.include?(term)
          }
        end
        items = case sort_by
        when "first_seen" then items.sort_by { |p| -p[:first_seen] }
        when "count" then items.sort_by { |p| -p[:count] }
        else items.sort_by { |p| -p[:last_seen] }
        end
        (items.slice(offset, limit) || []).map(&:dup)
      end

      def new_problem_attrs(occurrence, ts)
        {
          id: occurrence["fingerprint"],
          project: occurrence["project"],
          exception_class: occurrence["exception_class"],
          title: build_problem_title(occurrence),
          message: occurrence["message"],
          count: 1,
          status: "open",
          first_seen: ts,
          last_seen: ts,
          resolved_at: nil
        }
      end

      # Upsert rule for a repeat occurrence: reopens the problem if resolved.
      def touched_problem_attrs(existing, occurrence, ts)
        reopening = existing[:status] == "resolved"
        existing.merge(
          count: existing[:count] + 1,
          first_seen: [existing[:first_seen], ts].min,
          last_seen: [existing[:last_seen], ts].max,
          message: occurrence["message"],
          status: reopening ? "open" : existing[:status],
          resolved_at: reopening ? nil : existing[:resolved_at]
        )
      end

      def build_problem_title(occurrence)
        "#{occurrence["exception_class"]}: #{occurrence["message"]}"[0, PROBLEM_TITLE_MAX]
      end

      # Maps a string-keyed stored problem record to the symbol-keyed shape.
      def problem_from_strings(h)
        {
          id: h["id"],
          project: h["project"],
          exception_class: h["exception_class"],
          title: h["title"],
          message: h["message"],
          count: h["count"],
          status: h["status"],
          first_seen: h["first_seen"],
          last_seen: h["last_seen"],
          resolved_at: h["resolved_at"]
        }
      end

      # Shared in-memory error-data read/purge layer for backends holding whole
      # collections in Ruby (Memory, File, Redis). The mutating helpers
      # (!-suffixed) must receive the live collections, inside whatever
      # synchronization the caller owns. Works on plain Hash/Array and their
      # concurrent-ruby counterparts.

      # list_server_events filter pipeline; `after` is an exclusive cursor.
      def filter_server_events(events, project:, name:, level:, session_id:, after:, limit:)
        items = events
        items = items.select { |e| e["project"] == project } unless project.nil?
        items = items.select { |e| e["name"] == name } if name
        items = items.select { |e| e["level"] == level } if level
        items = items.select { |e| e["session_id"] == session_id } if session_id
        items = items.select { |e| e["timestamp"].to_f > after.to_f } if after
        items = items.sort_by { |e| e["timestamp"].to_f }
        items.first(limit)
      end

      def rows_for_session(rows, session_id, limit:)
        result = rows
          .select { |row| row["session_id"] == session_id }
          .sort_by { |row| row["timestamp"].to_f }
        limit ? result.first(limit) : result
      end

      # Distinct session ids across an occurrence list, most recently seen first
      # (by each session's latest occurrence). Occurrences without a session_id
      # are skipped.
      def latest_session_ids(occurrences, limit:)
        latest_by_session = {}
        occurrences.each do |occ|
          sid = occ["session_id"]
          next unless sid
          ts = occ["timestamp"].to_f
          latest_by_session[sid] = [latest_by_session[sid] || ts, ts].max
        end
        ids = latest_by_session.sort_by { |_sid, ts| -ts }.map(&:first)
        limit ? ids.first(limit) : ids
      end

      # Ages out error data older than the cutoff, in place: server events and
      # occurrence rows by timestamp, then problems whose last_seen is stale
      # (along with their remaining occurrences).
      def purge_error_collections!(problems, occurrences, server_events, cutoff)
        server_events.reject! { |event| event["timestamp"].to_f < cutoff }

        occurrences.each_pair do |_fp, list|
          list.reject! { |occ| occ["timestamp"].to_f < cutoff }
        end

        stale_fps = problems.each_pair.filter_map { |fp, problem| fp if problem[:last_seen] < cutoff }
        stale_fps.each do |fp|
          problems.delete(fp)
          occurrences.delete(fp)
        end
      end

      # Evicts the least-recently-seen problems (and their occurrences), in
      # place, until at most `max` remain. No-op when max is nil.
      def evict_oldest_problems!(problems, occurrences, max)
        return unless max && problems.size > max

        to_evict = problems.size - max
        oldest_fps = problems.each_pair
          .sort_by { |_fp, problem| problem[:last_seen] }
          .first(to_evict)
          .map(&:first)
        oldest_fps.each do |fp|
          problems.delete(fp)
          occurrences.delete(fp)
        end
      end
    end
  end
end
