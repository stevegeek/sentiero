# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"

module Sentiero
  module Stores
    class File < Store
      # File-based store, single-process dev/test only. Each session is a
      # directory: meta.json (timestamps, metadata) + {window_id}.jsonl
      # (one JSON event per line).

      def initialize(path:, limits: nil)
        @limits = limits
        @root = ::File.expand_path(path)
        FileUtils.mkdir_p(@root)
      end

      def save_events(ref, events)
        return if events.nil? || events.empty?

        validate_window_ref!(ref)
        session_id = ref.session_id
        window_id = ref.window_id

        now = Time.now.to_f
        session_dir = session_path(session_id)
        FileUtils.mkdir_p(session_dir)

        event_timestamps = events.filter_map { |event| event["timestamp"]&.to_f }
        batch_min = event_timestamps.min
        batch_max = event_timestamps.max

        ::File.open(window_path(session_id, window_id), "a") do |file|
          file.flock(::File::LOCK_EX)
          file.write(serialize_events(events))
        end

        update_meta(session_id) do |meta|
          if meta
            meta["updated_at"] = now
            meta["first_event_at"] = [meta["first_event_at"], batch_min].compact.min if batch_min
            meta["last_event_at"] = [meta["last_event_at"], batch_max].compact.max if batch_max
          else
            meta = {
              "created_at" => now,
              "updated_at" => now,
              "first_event_at" => batch_min,
              "last_event_at" => batch_max,
              "metadata" => nil
            }
          end
          meta
        end

        enforce_max_events(session_id)
        enforce_max_sessions

        nil
      end

      def list_sessions(limit:, offset: 0, since: nil, until_time: nil, sort_by: nil, search: nil)
        session_ids = list_session_ids
        return [] if session_ids.empty?

        summaries = session_ids.filter_map { |sid| build_summary(sid) }

        if since
          since_f = since.to_f
          summaries = summaries.select { |summary| summary[:updated_at] >= since_f }
        end
        if until_time
          until_f = until_time.to_f
          summaries = summaries.select { |summary| summary[:updated_at] <= until_f }
        end
        if search && !search.empty?
          summaries = summaries.select { |summary| session_matches_search?(summary, search) }
        end

        case sort_by
        when "created_at"
          summaries.sort_by! { |summary| -summary[:created_at] }
        when "event_count"
          summaries.sort_by! { |summary| -summary[:event_count] }
        else
          summaries.sort_by! { |summary| -summary[:updated_at] }
        end

        summaries.slice(offset, limit) || []
      end

      def get_session(session_id)
        validate_id!(session_id)
        meta = read_meta(session_id)
        return nil unless meta

        window_ids = list_window_ids(session_id)
        return nil if window_ids.empty?

        window_data = window_ids.map { |wid|
          events = read_window_events(session_id, wid)
          timestamps = events.filter_map { |event| event["timestamp"]&.to_f }
          window = {window_id: wid, event_count: events.size}
          if timestamps.any?
            window[:first_event_at] = timestamps.min
            window[:last_event_at] = timestamps.max
          end
          window
        }

        {session_id: session_id, windows: window_data}.merge(meta_fields(meta))
      end

      def get_events(ref, after: nil, limit: nil)
        validate_window_ref!(ref)
        session_id = ref.session_id
        window_id = ref.window_id
        events = read_window_events(session_id, window_id).sort_by { |event| event["timestamp"].to_f }

        if after
          idx = events.index { |event| event["timestamp"].to_f > after.to_f }
          events = idx ? events[idx..] : []
        end

        limit ? events.first(limit) : events
      end

      def save_metadata(session_id, metadata)
        return unless metadata.is_a?(Hash) && !metadata.empty?
        validate_id!(session_id)
        validate_metadata!(metadata)

        update_meta(session_id) do |meta|
          next nil unless meta

          existing = meta["metadata"] || {}
          meta["metadata"] = existing.merge(metadata.transform_keys(&:to_s))
          meta
        end
        nil
      end

      def delete_session(session_id)
        validate_id!(session_id)
        dir = session_path(session_id)
        FileUtils.rm_rf(dir) if ::File.directory?(dir)

        update_error_data do |_problems, occurrences, server_events|
          occurrences.each_value { |list| list.reject! { |occ| occ["session_id"] == session_id } }
          server_events.reject! { |event| event["session_id"] == session_id }
        end

        nil
      end

      def delete_window(ref)
        validate_window_ref!(ref)
        session_id = ref.session_id
        window_id = ref.window_id
        FileUtils.rm_f(window_path(session_id, window_id))

        # Only the session directory (meta.json + window files) is replay
        # data; error data lives in the shared root-level JSON files, so
        # this must not go through delete_session (which also erases those).
        remaining = list_window_ids(session_id)
        FileUtils.rm_rf(session_path(session_id)) if remaining.empty?
        nil
      end

      def save_occurrence(occurrence)
        validate_occurrence!(occurrence)
        fp = occurrence["fingerprint"]
        ts = occurrence["timestamp"].to_f
        occ_id = SecureRandom.uuid
        stored = occurrence.merge("id" => occ_id)

        update_error_data do |problems, occurrences, _server_events|
          existing = problems[fp]
          problems[fp] = existing ? touched_problem_attrs(existing, occurrence, ts) : new_problem_attrs(occurrence, ts)
          occurrences[fp] ||= []
          occurrences[fp] << stored
          evict_oldest_problems!(problems, occurrences, limits.max_problems)
        end
        save_metadata(occurrence["session_id"], {"has_errors" => true}) if occurrence["session_id"]
        fp
      end

      def list_problems(project:, limit:, offset: 0, status: nil, sort_by: nil, search: nil, since: nil, until_time: nil)
        problems, _occurrences, _server_events = read_error_data
        filter_and_page_problems(
          problems.values,
          project: project,
          status: status,
          since: since,
          until_time: until_time,
          search: search,
          sort_by: sort_by,
          offset: offset,
          limit: limit
        )
      end

      def get_problem(problem_id)
        validate_id!(problem_id)
        problems, _occurrences, _server_events = read_error_data
        problems[problem_id]&.dup
      end

      def get_occurrences(problem_id, after: nil, limit: nil)
        validate_id!(problem_id)
        _problems, occurrences, _server_events = read_error_data
        list = occurrences[problem_id] || []
        result = list.sort_by { |occ| occ["timestamp"].to_f }
        result = result.select { |occ| occ["timestamp"].to_f > after.to_f } if after
        limit ? result.first(limit) : result
      end

      def count_occurrences(problem_id, after: nil)
        validate_id!(problem_id)
        _problems, occurrences, _server_events = read_error_data
        list = occurrences[problem_id] || []
        return list.size unless after
        after_f = after.to_f
        list.count { |occ| occ["timestamp"].to_f > after_f }
      end

      def update_problem_status(problem_id, status)
        validate_id!(problem_id)
        validate_status!(status)
        update_error_data do |problems, _occurrences, _server_events|
          existing = problems[problem_id]
          next unless existing

          problems[problem_id] = existing.merge(
            status: status,
            resolved_at: (status == "resolved") ? Time.now.to_f : nil
          )
        end
        nil
      end

      def save_server_event(event)
        validate_server_event!(event)
        stored = event.merge("id" => SecureRandom.uuid)
        update_error_data do |_problems, _occurrences, server_events|
          server_events << stored
          enforce_max_server_events!(server_events)
        end
        nil
      end

      def get_server_event(event_id)
        validate_id!(event_id)
        _problems, _occurrences, server_events = read_error_data
        server_events.find { |e| e["id"] == event_id }
      end

      def list_server_events(project:, limit:, name: nil, level: nil, session_id: nil, after: nil)
        _problems, _occurrences, server_events = read_error_data
        filter_server_events(
          server_events,
          project: project,
          name: name,
          level: level,
          session_id: session_id,
          after: after,
          limit: limit
        )
      end

      def occurrences_for_session(session_id, limit: nil)
        validate_id!(session_id)
        _problems, occurrences, _server_events = read_error_data
        rows_for_session(occurrences.values.flatten, session_id, limit: limit)
      end

      def server_events_for_session(session_id, limit: nil)
        validate_id!(session_id)
        _problems, _occurrences, server_events = read_error_data
        rows_for_session(server_events, session_id, limit: limit)
      end

      def session_ids_for_problem(problem_id, limit: nil)
        validate_id!(problem_id)
        _problems, occurrences, _server_events = read_error_data
        latest_session_ids(occurrences[problem_id] || [], limit: limit)
      end

      def clear!
        FileUtils.rm_rf(Dir.glob(::File.join(@root, "*")))
        nil
      end

      # Scan meta.json directly: the base list_sessions path is capped and
      # newest-first, so it would never see the oldest (stale) sessions.
      def purge_older_than(seconds)
        cutoff = Time.now.to_f - seconds

        stale = list_session_ids.select { |sid|
          updated_at = read_meta(sid)&.fetch("updated_at", nil)
          updated_at && updated_at < cutoff
        }

        stale.each { |sid| delete_session(sid) }
        deleted = stale.size

        purge_error_data_older_than!(cutoff)

        deleted
      end

      private

      def session_path(session_id)
        path = ::File.join(@root, session_id)
        unless path.start_with?(@root + ::File::SEPARATOR)
          raise ArgumentError, "path traversal detected: #{session_id.inspect}"
        end
        path
      end

      def meta_path(session_id)
        ::File.join(session_path(session_id), "meta.json")
      end

      def window_path(session_id, window_id)
        ::File.join(session_path(session_id), "#{window_id}.jsonl")
      end

      def serialize_events(events)
        events.map { |event| JSON.generate(event) }.join("\n") + "\n"
      end

      def read_meta(session_id)
        path = meta_path(session_id)
        return nil unless ::File.exist?(path)

        JSON.parse(::File.read(path))
      rescue JSON::ParserError
        nil
      end

      def meta_fields(meta)
        fields = {
          created_at: meta["created_at"],
          updated_at: meta["updated_at"],
          first_event_at: meta["first_event_at"],
          last_event_at: meta["last_event_at"]
        }
        metadata = meta["metadata"]
        fields[:metadata] = metadata if metadata
        fields
      end

      def write_meta(session_id, meta)
        path = meta_path(session_id)
        tmp = "#{path}.tmp.#{Process.pid}"
        ::File.write(tmp, JSON.generate(meta))
        ::File.rename(tmp, path)
      end

      def update_meta(session_id)
        dir = session_path(session_id)
        FileUtils.mkdir_p(dir)
        path = meta_path(session_id)
        lock_path = "#{path}.lock"
        ::File.open(lock_path, ::File::RDWR | ::File::CREAT, 0o600) do |lock|
          lock.flock(::File::LOCK_EX)
          meta = read_meta(session_id)
          meta = yield meta
          write_meta(session_id, meta) if meta
        end
      end

      def list_session_ids
        return [] unless ::File.directory?(@root)
        Dir.children(@root).select { |name|
          ::File.directory?(::File.join(@root, name))
        }
      end

      def list_window_ids(session_id)
        dir = session_path(session_id)
        return [] unless ::File.directory?(dir)

        Dir.children(dir)
          .select { |f| f.end_with?(".jsonl") }
          .map { |f| f.delete_suffix(".jsonl") }
      end

      def read_window_events(session_id, window_id)
        path = window_path(session_id, window_id)
        return [] unless ::File.exist?(path)

        # Shared lock so a read can't observe a half-written line concurrent with
        # a LOCK_EX append; the rescue below is a belt-and-braces fallback.
        lines = ::File.open(path, "r") do |f|
          f.flock(::File::LOCK_SH)
          f.readlines(chomp: true)
        end

        lines.filter_map do |line|
          next if line.empty?

          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end
      end

      def build_summary(session_id)
        meta = read_meta(session_id)
        return nil unless meta

        window_ids = list_window_ids(session_id)
        event_count = window_ids.sum { |wid| read_window_events(session_id, wid).size }

        summary_hash(
          session_id: session_id,
          window_ids: window_ids,
          event_count: event_count,
          created_at: meta["created_at"],
          updated_at: meta["updated_at"],
          first_event_at: meta["first_event_at"],
          last_event_at: meta["last_event_at"],
          metadata: meta["metadata"]
        )
      end

      def enforce_max_events(session_id)
        max_events = limits.max_events_per_session
        return unless max_events

        window_ids = list_window_ids(session_id)
        events_by_window = window_ids.map { |wid| [wid, read_window_events(session_id, wid)] }
        total = events_by_window.sum { |_, events| events.size }
        return unless total > max_events

        trim_windows(events_by_window, max_events).each do |wid, remaining|
          path = window_path(session_id, wid)
          if remaining.empty?
            FileUtils.rm_f(path)
          else
            ::File.write(path, serialize_events(remaining))
          end
        end
      end

      def trim_windows(events_by_window, max_events)
        excess = events_by_window.sum { |_, events| events.size } - max_events

        sorted = events_by_window.sort_by { |_, events| events.first&.fetch("timestamp", 0) || 0 }

        kept = {}
        sorted.each do |wid, events|
          break if excess <= 0

          drop = [excess, events.size].min
          excess -= drop
          kept[wid] = events.drop(drop)
        end
        kept
      end

      def enforce_max_sessions
        max_sessions = limits.max_sessions
        return unless max_sessions

        session_ids = list_session_ids
        return unless session_ids.size > max_sessions

        sorted = session_ids
          .filter_map { |sid|
            meta = read_meta(sid)
            meta ? [sid, meta["updated_at"]] : nil
        }
          .sort_by(&:last)

        to_evict = session_ids.size - max_sessions
        sorted.first(to_evict).each { |sid, _| delete_session(sid) }
      end

      # Error data lives in three root-level JSON files, serialised by one lock:
      #   problems.json      – fingerprint => problem hash
      #   occurrences.json   – fingerprint => [occurrence, ...]
      #   server_events.json – [server event, ...]
      def error_data_path(name)
        ::File.join(@root, name)
      end

      def error_lock_path
        ::File.join(@root, "error_data.lock")
      end

      def read_error_json(name)
        path = error_data_path(name)
        return nil unless ::File.exist?(path)
        JSON.parse(::File.read(path))
      rescue JSON::ParserError
        nil
      end

      def read_error_data
        raw_problems = read_error_json("problems.json") || {}
        raw_occurrences = read_error_json("occurrences.json") || {}
        raw_server_events = read_error_json("server_events.json") || []

        problems = raw_problems.transform_values { |p| problem_from_strings(p) }
        [problems, raw_occurrences, raw_server_events]
      end

      def write_error_data(problems, occurrences, server_events)
        raw_problems = problems.transform_values { |p| stringify_problem(p) }
        [
          ["problems.json", raw_problems],
          ["occurrences.json", occurrences],
          ["server_events.json", server_events]
        ].each do |name, data|
          path = error_data_path(name)
          tmp = "#{path}.tmp.#{Process.pid}"
          ::File.write(tmp, JSON.generate(data))
          ::File.rename(tmp, path)
        end
      end

      def update_error_data
        ::File.open(error_lock_path, ::File::RDWR | ::File::CREAT, 0o600) do |lock|
          lock.flock(::File::LOCK_EX)
          problems, occurrences, server_events = read_error_data
          yield problems, occurrences, server_events
          write_error_data(problems, occurrences, server_events)
        end
      end

      def stringify_problem(p)
        {
          "id" => p[:id],
          "project" => p[:project],
          "exception_class" => p[:exception_class],
          "title" => p[:title],
          "message" => p[:message],
          "count" => p[:count],
          "status" => p[:status],
          "first_seen" => p[:first_seen],
          "last_seen" => p[:last_seen],
          "resolved_at" => p[:resolved_at]
        }
      end

      def purge_error_data_older_than!(cutoff)
        update_error_data do |problems, occurrences, server_events|
          purge_error_collections!(problems, occurrences, server_events, cutoff)
        end
      end

      def enforce_max_server_events!(server_events)
        max = limits.max_server_events
        return unless max && server_events.size > max

        excess = server_events.size - max
        server_events.shift(excess)
      end
    end
  end
end
