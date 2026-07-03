# frozen_string_literal: true

require "json"
require "securerandom"
require "monitor"

# Optional dependency: load it if present, else the initializer below raises
# a LoadError with install instructions.
begin
  require "sqlite3"
rescue LoadError
end

module Sentiero
  module Stores
    class SQLite < Store
      # Loaded after the class line above establishes SQLite < Store, so
      # schema.rb's own `class SQLite` reopen doesn't hit a superclass mismatch.
      require_relative "sqlite/schema"

      # Single-file SQLite store for single-process production and dev.
      # Requires the sqlite3 gem; `require "sentiero/stores/sqlite"` to load.

      # Accumulates "column op ?" fragments and their bind params for a WHERE
      # clause, so the six list/count methods below don't hand-roll the same
      # conditions/params pair. #clause is "" (no WHERE) when nothing was added.
      class Where
        attr_reader :params

        def initialize
          @conditions = []
          @params = []
        end

        def add(condition, *values)
          @conditions << condition
          @params.concat(values)
          self
        end

        def clause
          @conditions.empty? ? "" : "WHERE #{@conditions.join(" AND ")}"
        end
      end

      def initialize(path: "sentiero.db", limits: nil)
        unless defined?(::SQLite3)
          raise LoadError, "The sqlite3 gem is required for Sentiero::Stores::SQLite. Add `gem 'sqlite3'` to your Gemfile."
        end

        @limits = limits
        @monitor = Monitor.new
        @path = path
        @db = create_database
        Schema.create(@db)
      end

      def save_events(ref, events)
        return if events.nil? || events.empty?

        validate_window_ref!(ref)
        session_id, window_id = ref.session_id, ref.window_id

        now = Time.now.to_f
        event_timestamps = events.filter_map { |e| e["timestamp"]&.to_f }
        batch_min = event_timestamps.min
        batch_max = event_timestamps.max

        @db.transaction do
          existing = @db.get_first_row("SELECT id, first_event_at, last_event_at FROM sessions WHERE session_id = ?", [session_id])

          if existing
            new_first = batch_min ? [existing["first_event_at"], batch_min].compact.min : existing["first_event_at"]
            new_last = batch_max ? [existing["last_event_at"], batch_max].compact.max : existing["last_event_at"]

            @db.execute(
              "UPDATE sessions SET updated_at = ?, first_event_at = ?, last_event_at = ? WHERE session_id = ?",
              [now, new_first, new_last, session_id]
            )
          else
            @db.execute(
              "INSERT INTO sessions (session_id, created_at, updated_at, first_event_at, last_event_at, metadata) VALUES (?, ?, ?, ?, ?, NULL)",
              [session_id, now, now, batch_min, batch_max]
            )
          end

          stmt = @db.prepare("INSERT INTO events (session_id, window_id, timestamp, data) VALUES (?, ?, ?, ?)")
          begin
            events.each do |event|
              stmt.execute(session_id, window_id, event["timestamp"]&.to_f, JSON.generate(event))
            end
          ensure
            stmt.close
          end

          enforce_max_events(session_id)
          enforce_max_sessions(session_id)
        end

        nil
      end

      # Batched scan: avoids the base's get_session + get_events-per-window N+1.
      SCAN_IN_CHUNK = 500

      def each_session_events(limit: nil, since: nil, until_time: nil)
        return enum_for(:each_session_events, limit: limit, since: since, until_time: until_time) unless block_given?

        cap = limit || limits.analytics_max_scan_sessions
        rows = scan_session_rows(cap, since, until_time)
        return if rows.empty?

        events = events_by_session_window(rows.map { |row| row["session_id"] })
        rows.each do |row|
          windows = events[row["session_id"]]
          next unless windows

          summary = scan_summary(row, windows)
          windows.each { |window_id, window_events| yield summary, window_id, window_events }
        end
      end

      def list_sessions(limit:, offset: 0, since: nil, until_time: nil, sort_by: nil, search: nil)
        where = Where.new
        where.add("s.updated_at >= ?", since.to_f) if since
        where.add("s.updated_at <= ?", until_time.to_f) if until_time
        if search && !search.empty?
          pattern = "%#{search}%"
          where.add("(s.session_id LIKE ? OR COALESCE(s.metadata, '') LIKE ?)", pattern, pattern)
        end

        order_clause = case sort_by
        when "created_at"
          "ORDER BY s.created_at DESC"
        when "event_count"
          "ORDER BY event_count DESC"
        else
          "ORDER BY s.updated_at DESC"
        end

        sql = <<~SQL
          SELECT s.session_id, s.created_at, s.updated_at, s.first_event_at, s.last_event_at, s.metadata,
                 COUNT(e.id) AS event_count
          FROM sessions s
          LEFT JOIN events e ON e.session_id = s.session_id
          #{where.clause}
          GROUP BY s.id
          #{order_clause}
          LIMIT ? OFFSET ?
        SQL

        rows = @db.execute(sql, where.params + [limit, offset])

        rows.map { |row|
          window_ids = @db.execute(
            "SELECT DISTINCT window_id FROM events WHERE session_id = ?", [row["session_id"]]
          ).map { |window_row| window_row["window_id"] }

          summary_hash(
            session_id: row["session_id"],
            window_ids: window_ids,
            event_count: row["event_count"],
            created_at: row["created_at"],
            updated_at: row["updated_at"],
            first_event_at: row["first_event_at"],
            last_event_at: row["last_event_at"],
            metadata: row["metadata"] && JSON.parse(row["metadata"])
          )
        }
      end

      def get_session(session_id)
        validate_id!(session_id)

        row = @db.get_first_row("SELECT * FROM sessions WHERE session_id = ?", [session_id])
        return nil unless row

        window_stats = @db.execute(
          "SELECT window_id, COUNT(*) AS cnt, MIN(timestamp) AS min_ts, MAX(timestamp) AS max_ts FROM events WHERE session_id = ? GROUP BY window_id",
          [session_id]
        )

        window_data = window_stats.map { |stats|
          window = {window_id: stats["window_id"], event_count: stats["cnt"]}
          window[:first_event_at] = stats["min_ts"] if stats["min_ts"]
          window[:last_event_at] = stats["max_ts"] if stats["max_ts"]
          window
        }

        result = {
          session_id: session_id,
          windows: window_data,
          created_at: row["created_at"],
          updated_at: row["updated_at"],
          first_event_at: row["first_event_at"],
          last_event_at: row["last_event_at"]
        }

        if row["metadata"]
          parsed = JSON.parse(row["metadata"])
          result[:metadata] = parsed unless empty_metadata?(parsed)
        end

        result
      end

      def get_events(ref, after: nil, limit: nil)
        validate_window_ref!(ref)
        session_id, window_id = ref.session_id, ref.window_id

        conditions = ["session_id = ?", "window_id = ?"]
        params = [session_id, window_id]

        if after
          conditions << "timestamp > ?"
          params << after.to_f
        end

        sql = "SELECT data FROM events WHERE #{conditions.join(" AND ")} ORDER BY timestamp ASC"
        if limit
          sql += " LIMIT ?"
          params << limit.to_i
        end

        @db.execute(sql, params).map { |event_row| JSON.parse(event_row["data"]) }
      end

      def save_metadata(session_id, metadata)
        return unless metadata.is_a?(Hash) && !metadata.empty?

        validate_id!(session_id)
        validate_metadata!(metadata)

        @db.transaction do
          row = @db.get_first_row("SELECT metadata FROM sessions WHERE session_id = ?", [session_id])
          return unless row

          existing = row["metadata"] ? JSON.parse(row["metadata"]) : {}
          merged = existing.merge(metadata.transform_keys(&:to_s))
          @db.execute("UPDATE sessions SET metadata = ? WHERE session_id = ?", [JSON.generate(merged), session_id])
        end
        nil
      end

      def delete_session(session_id)
        validate_id!(session_id)

        @db.transaction do
          @db.execute("DELETE FROM events WHERE session_id = ?", [session_id])
          @db.execute("DELETE FROM sessions WHERE session_id = ?", [session_id])
          @db.execute("DELETE FROM occurrences WHERE session_id = ?", [session_id])
          @db.execute("DELETE FROM server_events WHERE session_id = ?", [session_id])
        end
        nil
      end

      def delete_window(ref)
        validate_window_ref!(ref)
        session_id, window_id = ref.session_id, ref.window_id

        @db.transaction do
          @db.execute("DELETE FROM events WHERE session_id = ? AND window_id = ?", [session_id, window_id])

          remaining = @db.get_first_value("SELECT COUNT(*) FROM events WHERE session_id = ?", [session_id])
          if remaining == 0
            @db.execute("DELETE FROM sessions WHERE session_id = ?", [session_id])
          end
        end
        nil
      end

      def save_occurrence(occurrence)
        validate_occurrence!(occurrence)
        fp = occurrence["fingerprint"]
        ts = occurrence["timestamp"].to_f
        occ_id = SecureRandom.uuid
        stored = occurrence.merge("id" => occ_id)

        # Native-SQL upsert mirroring the base new_problem_attrs/touched_problem_attrs.
        @db.transaction do
          existing = @db.get_first_row(
            "SELECT count, first_seen, last_seen, status, resolved_at FROM problems WHERE fingerprint = ?", [fp]
          )
          if existing
            reopening = existing["status"] == "resolved"
            @db.execute(
              "UPDATE problems SET count = count + 1, first_seen = ?, last_seen = ?, message = ?, status = ?, resolved_at = ? WHERE fingerprint = ?",
              [[existing["first_seen"], ts].min, [existing["last_seen"], ts].max, occurrence["message"],
                reopening ? "open" : existing["status"], reopening ? nil : existing["resolved_at"], fp]
            )
          else
            @db.execute(
              "INSERT INTO problems (fingerprint, project, exception_class, title, message, count, status, first_seen, last_seen, resolved_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)",
              [fp, occurrence["project"], occurrence["exception_class"], build_problem_title(occurrence),
                occurrence["message"], 1, "open", ts, ts]
            )
          end

          @db.execute(
            "INSERT INTO occurrences (occurrence_id, fingerprint, session_id, timestamp, data) VALUES (?, ?, ?, ?, ?)",
            [occ_id, fp, occurrence["session_id"], ts, JSON.generate(stored)]
          )

          enforce_max_problems
        end
        save_metadata(occurrence["session_id"], {"has_errors" => true}) if occurrence["session_id"]
        fp
      end

      # Native-SQL mirror of the base filter_and_page_problems.
      def list_problems(project:, limit:, offset: 0, status: nil, sort_by: nil, search: nil, since: nil, until_time: nil)
        where = Where.new
        where.add("project = ?", project) unless project.nil?
        where.add("status = ?", status) if status
        where.add("last_seen >= ?", since.to_f) if since
        where.add("last_seen <= ?", until_time.to_f) if until_time
        if search && !search.empty?
          pattern = "%#{search}%"
          where.add("(title LIKE ? OR exception_class LIKE ?)", pattern, pattern)
        end
        order = case sort_by
        when "first_seen" then "ORDER BY first_seen DESC"
        when "count" then "ORDER BY count DESC"
        else "ORDER BY last_seen DESC"
        end
        @db.execute("SELECT * FROM problems #{where.clause} #{order} LIMIT ? OFFSET ?", where.params + [limit, offset])
          .map { |row| problem_row_to_hash(row) }
      end

      def get_problem(problem_id)
        validate_id!(problem_id)
        row = @db.get_first_row("SELECT * FROM problems WHERE fingerprint = ?", [problem_id])
        row && problem_row_to_hash(row)
      end

      def get_occurrences(problem_id, after: nil, limit: nil)
        validate_id!(problem_id)
        where = Where.new.add("fingerprint = ?", problem_id)
        where.add("timestamp > ?", after.to_f) if after
        sql = "SELECT data FROM occurrences #{where.clause} ORDER BY timestamp ASC"
        params = where.params
        if limit
          sql += " LIMIT ?"
          params += [limit.to_i]
        end
        @db.execute(sql, params).map { |row| JSON.parse(row["data"]) }
      end

      # COUNT(*) on the (fingerprint, timestamp) index, no row materialization.
      def count_occurrences(problem_id, after: nil)
        validate_id!(problem_id)
        where = Where.new.add("fingerprint = ?", problem_id)
        where.add("timestamp > ?", after.to_f) if after
        @db.get_first_value("SELECT COUNT(*) FROM occurrences #{where.clause}", where.params)
      end

      def update_problem_status(problem_id, status)
        validate_id!(problem_id)
        validate_status!(status)
        resolved_at = (status == "resolved") ? Time.now.to_f : nil
        @db.execute("UPDATE problems SET status = ?, resolved_at = ? WHERE fingerprint = ?", [status, resolved_at, problem_id])
        nil
      end

      def save_server_event(event)
        validate_server_event!(event)
        ev_id = SecureRandom.uuid
        stored = event.merge("id" => ev_id)
        @db.transaction do
          @db.execute(
            "INSERT INTO server_events (event_id, project, name, level, session_id, timestamp, data) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [ev_id, event["project"], event["name"], event["level"], event["session_id"], event["timestamp"].to_f, JSON.generate(stored)]
          )
          enforce_max_server_events
        end
        nil
      end

      def get_server_event(event_id)
        validate_id!(event_id)
        row = @db.get_first_row("SELECT data FROM server_events WHERE event_id = ?", [event_id])
        row && JSON.parse(row["data"])
      end

      def list_server_events(project:, limit:, name: nil, level: nil, session_id: nil, after: nil)
        where = Where.new
        where.add("project = ?", project) unless project.nil?
        where.add("name = ?", name) if name
        where.add("level = ?", level) if level
        where.add("session_id = ?", session_id) if session_id
        where.add("timestamp > ?", after.to_f) if after
        @db.execute("SELECT data FROM server_events #{where.clause} ORDER BY timestamp ASC LIMIT ?", where.params + [limit])
          .map { |row| JSON.parse(row["data"]) }
      end

      def occurrences_for_session(session_id, limit: nil)
        validate_id!(session_id)
        sql = "SELECT data FROM occurrences WHERE session_id = ? ORDER BY timestamp ASC"
        params = [session_id]
        if limit
          sql += " LIMIT ?"
          params << limit.to_i
        end
        @db.execute(sql, params).map { |row| JSON.parse(row["data"]) }
      end

      def server_events_for_session(session_id, limit: nil)
        validate_id!(session_id)
        sql = "SELECT data FROM server_events WHERE session_id = ? ORDER BY timestamp ASC"
        params = [session_id]
        if limit
          sql += " LIMIT ?"
          params << limit.to_i
        end
        @db.execute(sql, params).map { |row| JSON.parse(row["data"]) }
      end

      def session_ids_for_problem(problem_id, limit: nil)
        validate_id!(problem_id)
        sql = "SELECT session_id, MAX(timestamp) AS ts FROM occurrences WHERE fingerprint = ? AND session_id IS NOT NULL GROUP BY session_id ORDER BY ts DESC"
        params = [problem_id]
        if limit
          sql += " LIMIT ?"
          params << limit.to_i
        end
        @db.execute(sql, params).map { |row| row["session_id"] }
      end

      def clear!
        @db.transaction do
          @db.execute("DELETE FROM events")
          @db.execute("DELETE FROM sessions")
          @db.execute("DELETE FROM problems")
          @db.execute("DELETE FROM occurrences")
          @db.execute("DELETE FROM server_events")
        end
        nil
      end

      def purge_older_than(seconds)
        cutoff = Time.now.to_f - seconds
        session_count = nil

        @db.transaction do
          @db.execute(
            "DELETE FROM events WHERE session_id IN (SELECT session_id FROM sessions WHERE updated_at < ?)",
            [cutoff]
          )
          @db.execute("DELETE FROM sessions WHERE updated_at < ?", [cutoff])
          session_count = @db.changes

          @db.execute("DELETE FROM server_events WHERE timestamp < ?", [cutoff])
          @db.execute("DELETE FROM occurrences WHERE timestamp < ?", [cutoff])
          @db.execute(
            "DELETE FROM occurrences WHERE fingerprint IN (SELECT fingerprint FROM problems WHERE last_seen < ?)",
            [cutoff]
          )
          @db.execute("DELETE FROM problems WHERE last_seen < ?", [cutoff])
        end

        session_count
      end

      private

      def empty_metadata?(parsed)
        parsed.nil? || (parsed.is_a?(Hash) && parsed.empty?)
      end

      def scan_session_rows(cap, since, until_time)
        where = Where.new
        where.add("updated_at >= ?", since.to_f) if since
        where.add("updated_at <= ?", until_time.to_f) if until_time
        @db.execute(
          "SELECT session_id, created_at, updated_at, first_event_at, last_event_at, metadata " \
          "FROM sessions #{where.clause} ORDER BY updated_at DESC LIMIT ?", where.params + [cap]
        )
      end

      def events_by_session_window(session_ids)
        grouped = Hash.new { |h, sid| h[sid] = {} }
        session_ids.each_slice(SCAN_IN_CHUNK) do |chunk|
          placeholders = (["?"] * chunk.size).join(",")
          @db.execute(
            "SELECT session_id, window_id, data FROM events WHERE session_id IN (#{placeholders}) ORDER BY timestamp ASC",
            chunk
          ).each do |row|
            (grouped[row["session_id"]][row["window_id"]] ||= []) << JSON.parse(row["data"])
          end
        end
        grouped
      end

      def scan_summary(row, windows)
        summary_hash(
          session_id: row["session_id"],
          window_ids: windows.keys,
          event_count: windows.values.sum(&:size),
          created_at: row["created_at"],
          updated_at: row["updated_at"],
          first_event_at: row["first_event_at"],
          last_event_at: row["last_event_at"],
          metadata: row["metadata"] && JSON.parse(row["metadata"])
        )
      end

      def create_database
        db = ::SQLite3::Database.new(@path)
        db.results_as_hash = true
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA foreign_keys=ON")
        db
      end

      def enforce_max_events(session_id)
        max_events = limits.max_events_per_session
        return unless max_events

        total = @db.get_first_value("SELECT COUNT(*) FROM events WHERE session_id = ?", [session_id])
        return unless total > max_events

        excess = total - max_events
        @db.execute(
          "DELETE FROM events WHERE id IN (SELECT id FROM events WHERE session_id = ? ORDER BY timestamp ASC LIMIT ?)",
          [session_id, excess]
        )
      end

      def enforce_max_sessions(protected_session_id)
        max_sessions = limits.max_sessions
        return unless max_sessions

        total = @db.get_first_value("SELECT COUNT(*) FROM sessions")
        return unless total > max_sessions

        to_evict = total - max_sessions
        oldest = @db.execute(
          "SELECT session_id FROM sessions WHERE session_id != ? ORDER BY updated_at ASC LIMIT ?",
          [protected_session_id, to_evict]
        ).map { |session_row| session_row["session_id"] }

        oldest.each do |sid|
          @db.execute("DELETE FROM events WHERE session_id = ?", [sid])
          @db.execute("DELETE FROM sessions WHERE session_id = ?", [sid])
        end
      end

      # Own row mapper (not base problem_from_strings): :id maps from the
      # fingerprint column, since the table has its own AUTOINCREMENT id.
      def problem_row_to_hash(row)
        {
          id: row["fingerprint"],
          project: row["project"],
          exception_class: row["exception_class"],
          title: row["title"],
          message: row["message"],
          count: row["count"],
          status: row["status"],
          first_seen: row["first_seen"],
          last_seen: row["last_seen"],
          resolved_at: row["resolved_at"]
        }
      end

      def enforce_max_problems
        max = limits.max_problems
        return unless max

        total = @db.get_first_value("SELECT COUNT(*) FROM problems")
        return unless total > max

        excess = total - max
        fps = @db.execute("SELECT fingerprint FROM problems ORDER BY last_seen ASC LIMIT ?", [excess]).map { |r| r["fingerprint"] }
        fps.each do |fp|
          @db.execute("DELETE FROM occurrences WHERE fingerprint = ?", [fp])
          @db.execute("DELETE FROM problems WHERE fingerprint = ?", [fp])
        end
      end

      def enforce_max_server_events
        max = limits.max_server_events
        return unless max

        total = @db.get_first_value("SELECT COUNT(*) FROM server_events")
        return unless total > max

        excess = total - max
        @db.execute("DELETE FROM server_events WHERE id IN (SELECT id FROM server_events ORDER BY timestamp ASC LIMIT ?)", [excess])
      end

      # Rack hands URL path segments over as ASCII-8BIT strings, and sqlite3
      # (>= 2.x) binds ASCII-8BIT params as BLOBs — so a TEXT-column lookup
      # with a Rack-supplied ID silently matches nothing. Re-tag binary string
      # arguments as UTF-8 on the way in (IDs are ASCII-only by validation, so
      # the bytes are unchanged). Nested payloads (events, metadata) come from
      # JSON.parse and are already UTF-8.
      utf8_arg = lambda do |value|
        case value
        when String
          (value.encoding == Encoding::ASCII_8BIT) ? value.dup.force_encoding(Encoding::UTF_8) : value
        when WindowRef
          WindowRef.new(utf8_arg.call(value.session_id), utf8_arg.call(value.window_id))
        else
          value
        end
      end

      # One shared SQLite3 connection can't be driven from multiple threads at once
      # (concurrent statements race on its single transaction state), and EventsApp
      # is a concurrent caller under Puma. Serialize every public op through one
      # reentrant Monitor: reentrant for internal calls (save_occurrence ->
      # save_metadata), wrap-all so new methods stay covered, defined last to see them.
      # The same wrapper applies utf8_arg to every argument (see above).
      synchronized = public_instance_methods(false)
      prepend(Module.new do
        synchronized.each do |method_name|
          define_method(method_name) do |*args, **kwargs, &block|
            args = args.map { |arg| utf8_arg.call(arg) }
            kwargs = kwargs.transform_values { |value| utf8_arg.call(value) }
            @monitor.synchronize { super(*args, **kwargs, &block) }
          end
        end
      end)
    end
  end
end
