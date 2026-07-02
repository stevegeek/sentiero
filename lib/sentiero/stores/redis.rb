# frozen_string_literal: true

require "json"
require "securerandom"

module Sentiero
  module Stores
    class Redis < Store
      # Loaded after the class line above establishes Redis < Store, so these
      # files' own `class Redis` reopen doesn't hit a superclass mismatch.
      require_relative "redis/keys"
      require_relative "redis/lua"

      # Key layout (all under @prefix): events in per-window sorted sets scored
      # by timestamp, session metadata in hashes, window membership in sets, and
      # a global sessions sorted set scored by updated_at. See Keys for the
      # exact key names and Lua for the scripts run via EVAL.
      def initialize(redis:, ttl: nil, prefix: "sentiero:", limits: nil)
        unless defined?(::Redis)
          raise LoadError, "The redis gem is required for Sentiero::Stores::Redis. Add `gem 'redis'` to your Gemfile."
        end

        @limits = limits
        @redis = redis
        @ttl = ttl
        @prefix = prefix
        @keys = Keys.new(prefix)
      end

      def save_events(ref, events)
        return if events.nil? || events.empty?

        validate_window_ref!(ref)
        session_id = ref.session_id
        window_id = ref.window_id

        now = Time.now.to_f
        events_key = @keys.events(session_id, window_id)
        windows_key = @keys.windows(session_id)
        session_key = @keys.session(session_id)

        event_timestamps = events.filter_map { |event| event["timestamp"]&.to_f }
        batch_min = event_timestamps.min
        batch_max = event_timestamps.max

        @redis.pipelined do |pipe|
          events.each_with_index do |event, i|
            score = event["timestamp"] || (now + i * 0.0001)
            member = JSON.generate(event.merge("_seq" => "#{now}_#{i}"))
            pipe.zadd(events_key, score, member)
          end

          pipe.sadd(windows_key, window_id)

          pipe.hsetnx(session_key, "created_at", now.to_s)
          pipe.hset(session_key, "updated_at", now.to_s)

          pipe.zadd(@keys.sessions, now, session_id)

          if @ttl
            pipe.expire(events_key, @ttl)
            pipe.expire(windows_key, @ttl)
            pipe.expire(session_key, @ttl)
            pipe.expire(@keys.sessions, @ttl)
          end
        end

        # Atomic compare-and-set of first/last event timestamps, hence Lua.
        update_event_timestamps(session_key, batch_min, batch_max)

        enforce_max_events(session_id)
        enforce_max_sessions

        nil
      end

      # Batched scan: three pipelined round-trips total instead of the base's
      # get_session + get_events per window.
      def each_session_events(limit: nil, since: nil, until_time: nil)
        return enum_for(:each_session_events, limit: limit, since: since, until_time: until_time) unless block_given?

        cap = limit || limits.analytics_max_scan_sessions
        min = since ? since.to_f.to_s : "-inf"
        max = until_time ? until_time.to_f.to_s : "+inf"
        session_ids = @redis.zrevrangebyscore(@keys.sessions, max, min, limit: [0, cap])
        return if session_ids.empty?

        meta_futures = {}
        window_futures = {}
        @redis.pipelined do |pipe|
          session_ids.each do |sid|
            meta_futures[sid] = pipe.hgetall(@keys.session(sid))
            window_futures[sid] = pipe.smembers(@keys.windows(sid))
          end
        end

        event_futures = {}
        @redis.pipelined do |pipe|
          session_ids.each do |sid|
            next if meta_futures[sid].value.empty?

            window_futures[sid].value.each do |wid|
              event_futures[[sid, wid]] = pipe.zrange(@keys.events(sid, wid), 0, -1)
            end
          end
        end

        session_ids.each do |sid|
          meta = meta_futures[sid].value
          next if meta.empty?

          window_ids = window_futures[sid].value
          next if window_ids.empty?

          windows = window_ids.to_h { |wid| [wid, parse_events(event_futures[[sid, wid]].value)] }
          summary = scan_summary(sid, meta, window_ids, windows.values.sum(&:size))
          windows.each { |wid, events| yield summary, wid, events }
        end
      end

      # Default sort with no search needs no summaries beyond the requested page:
      # ZREVRANGEBYSCORE with LIMIT pages the score-ordered sessions zset
      # directly. created_at/event_count sort or search need every matching
      # session's summary first, so those go through the general path below.
      def list_sessions(limit:, offset: 0, since: nil, until_time: nil, sort_by: nil, search: nil)
        min = since ? since.to_f.to_s : "-inf"
        max = until_time ? until_time.to_f.to_s : "+inf"

        if default_sort?(sort_by) && (search.nil? || search.empty?)
          session_ids = @redis.zrevrangebyscore(@keys.sessions, max, min, limit: [offset, limit])
          return build_session_summaries(session_ids)
        end

        session_ids = @redis.zrevrangebyscore(@keys.sessions, max, min)
        return [] if session_ids.empty?

        summaries = build_session_summaries(session_ids)

        summaries.select! { |summary| session_matches_search?(summary, search) } if search && !search.empty?

        case sort_by
        when "created_at"
          summaries.sort_by! { |summary| -summary[:created_at] }
        when "event_count"
          summaries.sort_by! { |summary| -summary[:event_count] }
        end
        # default sort needs no work: zrevrangebyscore already returns updated_at desc

        summaries.slice(offset, limit) || []
      end

      def get_session(session_id)
        validate_id!(session_id)
        meta = @redis.hgetall(@keys.session(session_id))
        return nil if meta.empty?

        window_ids = @redis.smembers(@keys.windows(session_id))
        return nil if window_ids.empty?

        window_data = window_ids.map do |wid|
          key = @keys.events(session_id, wid)
          first_scores = @redis.zrangebyscore(key, "-inf", "+inf", limit: [0, 1], with_scores: true)
          last_scores = @redis.zrevrangebyscore(key, "+inf", "-inf", limit: [0, 1], with_scores: true)
          {
            window_id: wid,
            event_count: @redis.zcard(key),
            first_event_at: first_scores.first&.last,
            last_event_at: last_scores.first&.last
          }
        end

        result = {
          session_id: session_id,
          windows: window_data,
          created_at: meta["created_at"].to_f,
          updated_at: meta["updated_at"].to_f,
          first_event_at: meta["first_event_at"]&.to_f,
          last_event_at: meta["last_event_at"]&.to_f
        }
        result[:metadata] = JSON.parse(meta["metadata"]) if meta["metadata"]
        result
      end

      def get_events(ref, after: nil, limit: nil)
        validate_window_ref!(ref)
        session_id = ref.session_id
        window_id = ref.window_id
        parse_events(zrange_page(@keys.events(session_id, window_id), after: after, limit: limit))
      end

      def save_metadata(session_id, metadata)
        return unless metadata.is_a?(Hash) && !metadata.empty?

        validate_id!(session_id)
        validate_metadata!(metadata)

        key = @keys.session(session_id)
        @redis.eval(Lua::SAVE_METADATA, keys: [key], argv: [JSON.generate(metadata.transform_keys(&:to_s))])
        nil
      end

      def delete_session(session_id)
        validate_id!(session_id)
        evict_session(session_id)
        erase_session_occurrences(session_id)
        erase_session_server_events(session_id)
        nil
      end

      def delete_window(ref)
        validate_window_ref!(ref)
        session_id = ref.session_id
        window_id = ref.window_id

        now = Time.now.to_f
        @redis.eval(
          Lua::DELETE_WINDOW,
          keys: [@keys.events(session_id, window_id), @keys.windows(session_id), @keys.session(session_id), @keys.sessions],
          argv: [window_id, session_id, now.to_s]
        )
        nil
      end

      def save_occurrence(occurrence)
        validate_occurrence!(occurrence)
        fp = occurrence["fingerprint"]
        ts = occurrence["timestamp"].to_f
        occ_id = SecureRandom.uuid
        stored = occurrence.merge("id" => occ_id)

        created = @redis.eval(
          Lua::PROBLEM_UPSERT,
          keys: [@keys.problem(fp), @keys.problems, @keys.problems_project(occurrence["project"])],
          argv: [fp, ts, occurrence["message"].to_s, JSON.generate(new_problem_attrs(occurrence, ts))]
        )
        enforce_max_problems if created == 1

        @redis.pipelined do |pipe|
          pipe.zadd(@keys.occurrences(fp), ts, JSON.generate(stored))
          if occurrence["session_id"]
            pipe.zadd(@keys.session_occurrences(occurrence["session_id"]), ts, JSON.generate(stored))
          end
        end

        save_metadata(occurrence["session_id"], {"has_errors" => true}) if occurrence["session_id"]
        fp
      end

      def list_problems(project:, limit:, offset: 0, status: nil, sort_by: nil, search: nil, since: nil, until_time: nil)
        fps = if project.nil?
          @redis.zrevrange(@keys.problems, 0, -1)
        else
          @redis.smembers(@keys.problems_project(project))
        end
        return [] if fps.empty?

        items = fps.filter_map do |fp|
          json = @redis.get(@keys.problem(fp))
          json ? problem_from_strings(JSON.parse(json)) : nil
        end

        filter_and_page_problems(
          items,
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
        json = @redis.get(@keys.problem(problem_id))
        json ? problem_from_strings(JSON.parse(json)) : nil
      end

      def get_occurrences(problem_id, after: nil, limit: nil)
        validate_id!(problem_id)
        raw = zrange_page(@keys.occurrences(problem_id), after: after, limit: limit)
        return [] if raw.nil? || raw.empty?

        raw.map { |json| JSON.parse(json) }
      end

      # ZCOUNT counts server-side without parsing a single member.
      def count_occurrences(problem_id, after: nil)
        validate_id!(problem_id)
        min = after ? "(#{after.to_f}" : "-inf"
        @redis.zcount(@keys.occurrences(problem_id), min, "+inf")
      end

      def update_problem_status(problem_id, status)
        validate_id!(problem_id)
        validate_status!(status)
        json = @redis.get(@keys.problem(problem_id))
        return nil unless json

        problem = JSON.parse(json)
        problem["status"] = status
        problem["resolved_at"] = (status == "resolved") ? Time.now.to_f : nil
        @redis.set(@keys.problem(problem_id), JSON.generate(problem))
        nil
      end

      def save_server_event(event)
        validate_server_event!(event)
        ev_id = SecureRandom.uuid
        stored = event.merge("id" => ev_id)
        ts = event["timestamp"].to_f
        @redis.pipelined do |pipe|
          pipe.zadd(@keys.server_events, ts, JSON.generate(stored))
          pipe.zadd(@keys.server_events_project(event["project"]), ts, JSON.generate(stored))
        end
        enforce_max_server_events
        nil
      end

      def get_server_event(event_id)
        validate_id!(event_id)
        # O(n) scan of the server_events zset, bounded by max_server_events.
        all_members = @redis.zrange(@keys.server_events, 0, -1)
        all_members.each do |json|
          event = JSON.parse(json)
          return event if event["id"] == event_id
        end
        nil
      end

      # LIMIT on the zset alone would return fewer than `limit` rows whenever
      # earlier events in the range don't match the filters, so page through
      # in chunks and filter each page before counting it against the limit.
      # Scanning is bounded by max_server_events, the same cap that already
      # bounds how many rows can exist in this zset.
      LIST_SERVER_EVENTS_SCAN_CHUNK = 500

      def list_server_events(project:, limit:, name: nil, level: nil, session_id: nil, after: nil)
        key = project.nil? ? @keys.server_events : @keys.server_events_project(project)
        min = after ? "(#{after.to_f}" : "-inf"
        max_scan = limits.max_server_events || Float::INFINITY

        matches = []
        offset = 0
        loop do
          batch = @redis.zrangebyscore(key, min, "+inf", limit: [offset, LIST_SERVER_EVENTS_SCAN_CHUNK])
          break if batch.empty?

          batch.each do |json|
            event = JSON.parse(json)
            next unless server_event_matches?(event, name: name, level: level, session_id: session_id)

            matches << event
            break if matches.size >= limit
          end

          offset += batch.size
          break if matches.size >= limit
          break if batch.size < LIST_SERVER_EVENTS_SCAN_CHUNK
          break if offset >= max_scan
        end

        matches
      end

      def occurrences_for_session(session_id, limit: nil)
        validate_id!(session_id)
        key = @keys.session_occurrences(session_id)
        raw = limit ? @redis.zrange(key, 0, limit - 1) : @redis.zrange(key, 0, -1)
        return [] if raw.nil? || raw.empty?

        raw.map { |json| JSON.parse(json) }
      end

      def server_events_for_session(session_id, limit: nil)
        validate_id!(session_id)
        raw = @redis.zrange(@keys.server_events, 0, -1)
        return [] if raw.nil? || raw.empty?

        items = raw.map { |json| JSON.parse(json) }
          .select { |e| e["session_id"] == session_id }
        limit ? items.first(limit) : items
      end

      def session_ids_for_problem(problem_id, limit: nil)
        validate_id!(problem_id)
        raw = @redis.zrange(@keys.occurrences(problem_id), 0, -1)
        return [] if raw.nil? || raw.empty?

        latest_session_ids(raw.map { |json| JSON.parse(json) }, limit: limit)
      end

      def clear!
        # SCAN, not KEYS: KEYS is O(N) over the whole keyspace and blocks the server.
        @redis.scan_each(match: "#{@prefix}*") { |key| @redis.del(key) }
        nil
      end

      PURGE_BATCH_SIZE = 500

      # Range-query the updated_at-scored sessions zset for stale ids, paged in
      # batches to bound memory. Orthogonal to the :ttl option: delete_session's
      # DEL/ZREM are no-ops on already-expired keys, so they never collide.
      def purge_older_than(seconds)
        cutoff = Time.now.to_f - seconds
        deleted = 0

        loop do
          batch = @redis.zrangebyscore(@keys.sessions, "-inf", "(#{cutoff}", limit: [0, PURGE_BATCH_SIZE])
          break if batch.empty?

          batch.each { |session_id| delete_session(session_id) }
          deleted += batch.size
        end

        purge_error_data_older_than!(cutoff)

        deleted
      end

      private

      def default_sort?(sort_by)
        sort_by.nil? || sort_by == "updated_at"
      end

      def server_event_matches?(event, name:, level:, session_id:)
        (name.nil? || event["name"] == name) &&
          (level.nil? || event["level"] == level) &&
          (session_id.nil? || event["session_id"] == session_id)
      end

      def update_event_timestamps(session_key, batch_min, batch_max)
        return unless batch_min || batch_max

        @redis.eval(
          Lua::UPDATE_TIMESTAMPS,
          keys: [session_key],
          argv: [batch_min.to_s, batch_max.to_s]
        )
      end

      def parse_events(raw)
        return [] if raw.nil? || raw.empty?

        raw.map do |json_str|
          event = JSON.parse(json_str)
          event.delete("_seq")
          event
        end
      end

      # Cap total events for a session, draining windows oldest-first (by their
      # earliest event score) so the newest events are kept.
      def enforce_max_events(session_id)
        max_events = limits.max_events_per_session
        return unless max_events

        window_ids = @redis.smembers(@keys.windows(session_id))
        return if window_ids.empty?

        cards = {}
        firsts = {}
        @redis.pipelined do |pipe|
          window_ids.each do |wid|
            key = @keys.events(session_id, wid)
            cards[wid] = pipe.zcard(key)
            firsts[wid] = pipe.zrange(key, 0, 0, with_scores: true)
          end
        end
        counts = cards.transform_values(&:value)
        return unless counts.values.sum > max_events

        excess = counts.values.sum - max_events
        ordered = window_ids.sort_by { |wid| firsts[wid].value.first&.last || 0 }
        emptied = []
        @redis.pipelined do |pipe|
          ordered.each do |wid|
            break if excess <= 0

            drop = [excess, counts[wid]].min
            next if drop <= 0

            pipe.zremrangebyrank(@keys.events(session_id, wid), 0, drop - 1)
            emptied << wid if drop == counts[wid]
            excess -= drop
          end
        end
        @redis.srem(@keys.windows(session_id), emptied) unless emptied.empty?
        nil
      end

      # Evict the oldest sessions (by updated_at) beyond the cap. Drops replay data
      # only, matching the other stores; the just-saved session is newest so is
      # never in the evicted set.
      def enforce_max_sessions
        max_sessions = limits.max_sessions
        return unless max_sessions

        excess = @redis.zcard(@keys.sessions) - max_sessions
        return unless excess > 0

        @redis.zrange(@keys.sessions, 0, excess - 1).each { |sid| evict_session(sid) }
      end

      # Atomic so a concurrent save_events adding a new window mid-delete can't
      # orphan its events key (which a read-then-pipeline sequence would miss).
      def evict_session(session_id)
        @redis.eval(
          Lua::EVICT_SESSION,
          keys: [@keys.windows(session_id), @keys.session(session_id), @keys.sessions],
          argv: [session_id, @prefix]
        )
        nil
      end

      def scan_summary(session_id, meta, window_ids, event_count)
        summary_hash(
          session_id: session_id,
          window_ids: window_ids,
          event_count: event_count,
          created_at: meta["created_at"].to_f,
          updated_at: meta["updated_at"].to_f,
          first_event_at: meta["first_event_at"]&.to_f,
          last_event_at: meta["last_event_at"]&.to_f,
          metadata: meta["metadata"] && JSON.parse(meta["metadata"])
        )
      end

      # Pipelined batch build of session summaries for list_sessions: two
      # round-trips total (meta+windows, then per-window zcard) instead of
      # issuing a separate hgetall + smembers + N zcard per session in sequence.
      # Mirrors each_session_events' own two-pipeline shape above.
      def build_session_summaries(session_ids)
        return [] if session_ids.empty?

        meta_futures = {}
        window_futures = {}
        @redis.pipelined do |pipe|
          session_ids.each do |sid|
            meta_futures[sid] = pipe.hgetall(@keys.session(sid))
            window_futures[sid] = pipe.smembers(@keys.windows(sid))
          end
        end

        count_futures = {}
        @redis.pipelined do |pipe|
          session_ids.each do |sid|
            next if meta_futures[sid].value.empty?

            window_futures[sid].value.each do |wid|
              count_futures[[sid, wid]] = pipe.zcard(@keys.events(sid, wid))
            end
          end
        end

        session_ids.filter_map do |sid|
          meta = meta_futures[sid].value
          next if meta.empty?

          window_ids = window_futures[sid].value
          event_count = window_ids.sum { |wid| count_futures[[sid, wid]].value }
          scan_summary(sid, meta, window_ids, event_count)
        end
      end

      # One page of a timestamp-scored zset: members strictly after the `after`
      # score (exclusive cursor) or from the start, capped at `limit`.
      def zrange_page(key, after:, limit:)
        if after
          opts = limit ? {limit: [0, limit]} : {}
          @redis.zrangebyscore(key, "(#{after.to_f}", "+inf", **opts)
        elsif limit
          @redis.zrange(key, 0, limit - 1)
        else
          @redis.zrange(key, 0, -1)
        end
      end

      def erase_session_occurrences(session_id)
        key = @keys.session_occurrences(session_id)
        members = @redis.zrange(key, 0, -1)

        members.each do |json|
          occ = JSON.parse(json)
          fp = occ["fingerprint"]
          next unless fp

          # `json` is byte-identical to the member save_occurrence stored in the
          # per-fingerprint zset (same serialized `stored`), so ZREM matches it.
          @redis.zrem(@keys.occurrences(fp), json)
        end

        @redis.del(key)
      end

      def erase_session_server_events(session_id)
        all_members = @redis.zrange(@keys.server_events, 0, -1)
        all_members.each do |json|
          event = JSON.parse(json)
          next unless event["session_id"] == session_id

          @redis.zrem(@keys.server_events, json)
          @redis.zrem(@keys.server_events_project(event["project"]), json) if event["project"]
        end
      end

      def purge_error_data_older_than!(cutoff)
        @redis.zremrangebyscore(@keys.server_events, "-inf", "(#{cutoff}")
        @redis.scan_each(match: "#{@prefix}server_events:project:*") do |key|
          @redis.zremrangebyscore(key, "-inf", "(#{cutoff}")
        end
        @redis.scan_each(match: "#{@prefix}occurrences:*") do |key|
          @redis.zremrangebyscore(key, "-inf", "(#{cutoff}")
        end

        stale_fps = @redis.zrangebyscore(@keys.problems, "-inf", "(#{cutoff}")
        stale_fps.each { |fp| delete_problem_records!(fp) }
      end

      def delete_problem_records!(fp)
        json = @redis.get(@keys.problem(fp))
        if json
          project = JSON.parse(json)["project"]
          @redis.srem(@keys.problems_project(project), fp) if project
        end
        @redis.del(@keys.problem(fp))
        @redis.del(@keys.occurrences(fp))
        @redis.zrem(@keys.problems, fp)
      end

      def enforce_max_problems
        max = limits.max_problems
        return unless max

        total = @redis.zcard(@keys.problems)
        return unless total > max

        excess = total - max
        fps = @redis.zrange(@keys.problems, 0, excess - 1)
        fps.each { |fp| delete_problem_records!(fp) }
      end

      def enforce_max_server_events
        max = limits.max_server_events
        return unless max

        total = @redis.zcard(@keys.server_events)
        return unless total > max

        excess = total - max
        oldest = @redis.zrange(@keys.server_events, 0, excess - 1)
        oldest.each do |json|
          event = JSON.parse(json)
          @redis.zrem(@keys.server_events_project(event["project"]), json) if event["project"]
          @redis.zrem(@keys.server_events, json)
        end
      end
    end
  end
end
