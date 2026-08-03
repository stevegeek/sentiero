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
      require_relative "sqlite/payload_codec"
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
        @path = path.to_s
        # In-memory databases are private to one connection, so they keep the
        # single shared connection serialized by @monitor. File-backed stores
        # get one connection per thread: WAL readers never block the writer, so
        # a slow dashboard scan can't stall recorder ingest (and vice versa).
        @in_memory = @path == ":memory:" || @path.start_with?("file::memory:")
        @tls_key = :"sentiero_sqlite_#{object_id}"
        @shared_db = create_connection if @in_memory
        Schema.create(db)
      end

      # event_type_counts / event_counts_by_day group on indexed columns and
      # never read payloads (see Schema for the column-order guarantee).
      def supports_event_aggregates?
        true
      end

      def save_events(ref, events)
        return if events.nil? || events.empty?

        validate_window_ref!(ref)
        session_id, window_id = ref.session_id, ref.window_id

        now = Time.now.to_f
        event_timestamps = events.filter_map { |e| e["timestamp"]&.to_f }
        batch_min = event_timestamps.min
        batch_max = event_timestamps.max

        db.transaction(:immediate) do
          existing = db.get_first_row("SELECT id, first_event_at, last_event_at FROM sessions WHERE session_id = ?", [session_id])

          if existing
            new_first = batch_min ? [existing["first_event_at"], batch_min].compact.min : existing["first_event_at"]
            new_last = batch_max ? [existing["last_event_at"], batch_max].compact.max : existing["last_event_at"]

            db.execute(
              "UPDATE sessions SET updated_at = ?, first_event_at = ?, last_event_at = ? WHERE session_id = ?",
              [now, new_first, new_last, session_id]
            )
          else
            db.execute(
              "INSERT INTO sessions (session_id, created_at, updated_at, first_event_at, last_event_at, metadata) VALUES (?, ?, ?, ?, ?, NULL)",
              [session_id, now, now, batch_min, batch_max]
            )
          end

          stmt = db.prepare("INSERT INTO events (session_id, window_id, timestamp, type, data) VALUES (?, ?, ?, ?, ?)")
          begin
            events.each do |event|
              type = event["type"]
              stmt.execute(session_id, window_id, event["timestamp"]&.to_f,
                type.is_a?(Integer) ? type : nil, PayloadCodec.encode(JSON.generate(event)))
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
      # Sessions materialized at once per scan — bounds peak memory (an
      # unchunked scan held every parsed payload before the first yield).
      EVENT_LOAD_CHUNK = 25

      def each_session_events(limit: nil, since: nil, until_time: nil, types: nil)
        unless block_given?
          return enum_for(:each_session_events, limit: limit, since: since, until_time: until_time, types: types)
        end

        cap = limit || limits.analytics_max_scan_sessions
        rows = scan_session_rows(cap, since, until_time)
        return if rows.empty?

        # Summaries always describe the whole session, so a typed scan reports
        # the same shape as a full one — including fully-filtered windows.
        shapes = window_shapes(rows.map { |row| row["session_id"] })

        rows.each_slice(EVENT_LOAD_CHUNK) do |chunk|
          events = events_by_session_window(chunk.map { |row| row["session_id"] }, types: types)

          chunk.each do |row|
            shape = shapes[row["session_id"]]
            next unless shape

            windows = events[row["session_id"]] || {}
            starts = shape.transform_values { |stats| stats[:start] }
            summary = scan_summary(row, shape.keys, shape.values.sum { |stats| stats[:count] }, starts)
            shape.each_key { |window_id| yield summary, window_id, windows[window_id] || [] }
          end
        end
      end

      # Index-assisted aggregate: groups on the type column without ever
      # reading a payload, unlike the base's parse-everything fallback.
      def event_type_counts(limit: nil, since: nil, until_time: nil)
        cap = limit || limits.analytics_max_scan_sessions
        session_ids = scan_session_rows(cap, since, until_time).map { |row| row["session_id"] }

        counts = {}
        session_ids.each_slice(SCAN_IN_CHUNK) do |chunk|
          placeholders = (["?"] * chunk.size).join(",")
          db.execute(
            "SELECT type, COUNT(*) AS cnt FROM events WHERE session_id IN (#{placeholders}) GROUP BY type",
            chunk
          ).each do |row|
            key = row["type"]
            counts[key] = (counts[key] || 0) + row["cnt"]
          end
        end
        counts
      end

      # Payload-free daily activity series: buckets on the indexed timestamp
      # column ('unixepoch' takes seconds, timestamps are ms).
      def event_counts_by_day(limit: nil, since: nil, until_time: nil)
        cap = limit || limits.analytics_max_scan_sessions
        session_ids = scan_session_rows(cap, since, until_time).map { |row| row["session_id"] }

        counts = {}
        session_ids.each_slice(SCAN_IN_CHUNK) do |chunk|
          placeholders = (["?"] * chunk.size).join(",")
          db.execute(
            "SELECT strftime('%Y-%m-%d', timestamp / 1000, 'unixepoch') AS day, COUNT(*) AS cnt " \
            "FROM events WHERE session_id IN (#{placeholders}) AND timestamp IS NOT NULL GROUP BY day",
            chunk
          ).each do |row|
            next unless row["day"]

            counts[row["day"]] = (counts[row["day"]] || 0) + row["cnt"]
          end
        end
        counts
      end

      def list_sessions(limit:, offset: 0, since: nil, until_time: nil, sort_by: nil, search: nil,
        min_duration_ms: nil, min_events: nil)
        where = Where.new
        where.add("s.updated_at >= ?", since.to_f) if since
        where.add("s.updated_at <= ?", until_time.to_f) if until_time
        if search && !search.empty?
          pattern = "%#{search}%"
          where.add("(s.session_id LIKE ? OR COALESCE(s.metadata, '') LIKE ?)", pattern, pattern)
        end
        if min_duration_ms
          where.add("s.first_event_at IS NOT NULL AND (s.last_event_at - s.first_event_at) >= ?", min_duration_ms)
        end

        order_clause = case sort_by
        when "created_at"
          "ORDER BY s.created_at DESC"
        when "event_count"
          "ORDER BY event_count DESC"
        else
          "ORDER BY s.updated_at DESC"
        end

        having = min_events ? "HAVING COUNT(e.id) >= ?" : ""
        sql = <<~SQL
          SELECT s.session_id, s.created_at, s.updated_at, s.first_event_at, s.last_event_at, s.metadata,
                 COUNT(e.id) AS event_count
          FROM sessions s
          LEFT JOIN events e ON e.session_id = s.session_id
          #{where.clause}
          GROUP BY s.id
          #{having}
          #{order_clause}
          LIMIT ? OFFSET ?
        SQL

        params = where.params
        params += [min_events] if min_events
        rows = db.execute(sql, params + [limit, offset])

        rows.map { |row|
          window_ids = db.execute(
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

        row = db.get_first_row("SELECT * FROM sessions WHERE session_id = ?", [session_id])
        return nil unless row

        window_stats = db.execute(
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

        db.execute(sql, params).map { |event_row| JSON.parse(PayloadCodec.decode(event_row["data"])) }
      end

      def save_metadata(session_id, metadata)
        return unless metadata.is_a?(Hash) && !metadata.empty?

        validate_id!(session_id)
        validate_metadata!(metadata)

        db.transaction(:immediate) do
          row = db.get_first_row("SELECT metadata FROM sessions WHERE session_id = ?", [session_id])
          return unless row

          existing = row["metadata"] ? JSON.parse(row["metadata"]) : {}
          merged = existing.merge(metadata.transform_keys(&:to_s))
          db.execute("UPDATE sessions SET metadata = ? WHERE session_id = ?", [JSON.generate(merged), session_id])
        end
        nil
      end

      def delete_session(session_id)
        validate_id!(session_id)

        db.transaction(:immediate) do
          db.execute("DELETE FROM events WHERE session_id = ?", [session_id])
          db.execute("DELETE FROM sessions WHERE session_id = ?", [session_id])
          db.execute("DELETE FROM occurrences WHERE session_id = ?", [session_id])
          db.execute("DELETE FROM server_events WHERE session_id = ?", [session_id])
        end
        nil
      end

      def delete_window(ref)
        validate_window_ref!(ref)
        session_id, window_id = ref.session_id, ref.window_id

        db.transaction(:immediate) do
          db.execute("DELETE FROM events WHERE session_id = ? AND window_id = ?", [session_id, window_id])

          remaining = db.get_first_value("SELECT COUNT(*) FROM events WHERE session_id = ?", [session_id])
          if remaining == 0
            db.execute("DELETE FROM sessions WHERE session_id = ?", [session_id])
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
        db.transaction(:immediate) do
          existing = db.get_first_row(
            "SELECT count, first_seen, last_seen, status, resolved_at FROM problems WHERE fingerprint = ?", [fp]
          )
          if existing
            reopening = existing["status"] == "resolved"
            db.execute(
              "UPDATE problems SET count = count + 1, first_seen = ?, last_seen = ?, message = ?, status = ?, resolved_at = ? WHERE fingerprint = ?",
              [[existing["first_seen"], ts].min, [existing["last_seen"], ts].max, occurrence["message"],
                reopening ? "open" : existing["status"], reopening ? nil : existing["resolved_at"], fp]
            )
          else
            db.execute(
              "INSERT INTO problems (fingerprint, project, exception_class, title, message, count, status, first_seen, last_seen, resolved_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)",
              [fp, occurrence["project"], occurrence["exception_class"], build_problem_title(occurrence),
                occurrence["message"], 1, "open", ts, ts]
            )
          end

          db.execute(
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
        db.execute("SELECT * FROM problems #{where.clause} #{order} LIMIT ? OFFSET ?", where.params + [limit, offset])
          .map { |row| problem_row_to_hash(row) }
      end

      def get_problem(problem_id)
        validate_id!(problem_id)
        row = db.get_first_row("SELECT * FROM problems WHERE fingerprint = ?", [problem_id])
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
        db.execute(sql, params).map { |row| JSON.parse(row["data"]) }
      end

      # COUNT(*) on the (fingerprint, timestamp) index, no row materialization.
      def count_occurrences(problem_id, after: nil)
        validate_id!(problem_id)
        where = Where.new.add("fingerprint = ?", problem_id)
        where.add("timestamp > ?", after.to_f) if after
        db.get_first_value("SELECT COUNT(*) FROM occurrences #{where.clause}", where.params)
      end

      def update_problem_status(problem_id, status)
        validate_id!(problem_id)
        validate_status!(status)
        resolved_at = (status == "resolved") ? Time.now.to_f : nil
        db.execute("UPDATE problems SET status = ?, resolved_at = ? WHERE fingerprint = ?", [status, resolved_at, problem_id])
        nil
      end

      def save_server_event(event)
        validate_server_event!(event)
        ev_id = SecureRandom.uuid
        stored = event.merge("id" => ev_id)
        db.transaction(:immediate) do
          db.execute(
            "INSERT INTO server_events (event_id, project, name, level, session_id, timestamp, data) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [ev_id, event["project"], event["name"], event["level"], event["session_id"], event["timestamp"].to_f, JSON.generate(stored)]
          )
          enforce_max_server_events
        end
        nil
      end

      def get_server_event(event_id)
        validate_id!(event_id)
        row = db.get_first_row("SELECT data FROM server_events WHERE event_id = ?", [event_id])
        row && JSON.parse(row["data"])
      end

      def list_server_events(project:, limit:, name: nil, level: nil, session_id: nil, after: nil)
        where = Where.new
        where.add("project = ?", project) unless project.nil?
        where.add("name = ?", name) if name
        where.add("level = ?", level) if level
        where.add("session_id = ?", session_id) if session_id
        where.add("timestamp > ?", after.to_f) if after
        db.execute("SELECT data FROM server_events #{where.clause} ORDER BY timestamp ASC LIMIT ?", where.params + [limit])
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
        db.execute(sql, params).map { |row| JSON.parse(row["data"]) }
      end

      def server_events_for_session(session_id, limit: nil)
        validate_id!(session_id)
        sql = "SELECT data FROM server_events WHERE session_id = ? ORDER BY timestamp ASC"
        params = [session_id]
        if limit
          sql += " LIMIT ?"
          params << limit.to_i
        end
        db.execute(sql, params).map { |row| JSON.parse(row["data"]) }
      end

      def session_ids_for_problem(problem_id, limit: nil)
        validate_id!(problem_id)
        sql = "SELECT session_id, MAX(timestamp) AS ts FROM occurrences WHERE fingerprint = ? AND session_id IS NOT NULL GROUP BY session_id ORDER BY ts DESC"
        params = [problem_id]
        if limit
          sql += " LIMIT ?"
          params << limit.to_i
        end
        db.execute(sql, params).map { |row| row["session_id"] }
      end

      def clear!
        db.transaction(:immediate) do
          db.execute("DELETE FROM events")
          db.execute("DELETE FROM sessions")
          db.execute("DELETE FROM problems")
          db.execute("DELETE FROM occurrences")
          db.execute("DELETE FROM server_events")
        end
        nil
      end

      def purge_older_than(seconds)
        cutoff = Time.now.to_f - seconds
        session_count = nil

        db.transaction(:immediate) do
          db.execute(
            "DELETE FROM events WHERE session_id IN (SELECT session_id FROM sessions WHERE updated_at < ?)",
            [cutoff]
          )
          db.execute("DELETE FROM sessions WHERE updated_at < ?", [cutoff])
          session_count = db.changes

          db.execute("DELETE FROM server_events WHERE timestamp < ?", [cutoff])
          db.execute("DELETE FROM occurrences WHERE timestamp < ?", [cutoff])
          db.execute(
            "DELETE FROM occurrences WHERE fingerprint IN (SELECT fingerprint FROM problems WHERE last_seen < ?)",
            [cutoff]
          )
          db.execute("DELETE FROM problems WHERE last_seen < ?", [cutoff])
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
        db.execute(
          "SELECT session_id, created_at, updated_at, first_event_at, last_event_at, metadata " \
          "FROM sessions #{where.clause} ORDER BY updated_at DESC LIMIT ?", where.params + [cap]
        )
      end

      def events_by_session_window(session_ids, types: nil)
        type_clause = ""
        type_params = []
        if types
          type_clause = " AND type IN (#{(["?"] * types.size).join(",")})"
          type_params = types.map(&:to_i)
        end

        grouped = Hash.new { |h, sid| h[sid] = {} }
        session_ids.each_slice(SCAN_IN_CHUNK) do |chunk|
          placeholders = (["?"] * chunk.size).join(",")
          db.execute(
            "SELECT session_id, window_id, data FROM events WHERE session_id IN (#{placeholders})#{type_clause} ORDER BY timestamp ASC",
            chunk + type_params
          ).each do |row|
            (grouped[row["session_id"]][row["window_id"]] ||= []) << JSON.parse(PayloadCodec.decode(row["data"]))
          end
        end
        grouped
      end

      # {session_id => {window_id => {count:, start:}}} — index-only, so a
      # typed scan reports full-session summaries without reading payloads.
      def window_shapes(session_ids)
        shapes = Hash.new { |h, sid| h[sid] = {} }
        session_ids.each_slice(SCAN_IN_CHUNK) do |chunk|
          placeholders = (["?"] * chunk.size).join(",")
          db.execute(
            "SELECT session_id, window_id, COUNT(*) AS cnt, MIN(timestamp) AS min_ts FROM events WHERE session_id IN (#{placeholders}) GROUP BY session_id, window_id",
            chunk
          ).each do |row|
            shapes[row["session_id"]][row["window_id"]] = {count: row["cnt"], start: row["min_ts"]}
          end
        end
        shapes
      end

      def scan_summary(row, window_ids, event_count, window_starts)
        summary_hash(
          session_id: row["session_id"],
          window_ids: window_ids,
          event_count: event_count,
          created_at: row["created_at"],
          updated_at: row["updated_at"],
          first_event_at: row["first_event_at"],
          last_event_at: row["last_event_at"],
          metadata: row["metadata"] && JSON.parse(row["metadata"])
        ).merge(window_starts: window_starts)
      end

      def db
        return @shared_db if @in_memory

        Thread.current[@tls_key] ||= create_connection
      end

      def create_connection
        conn = ::SQLite3::Database.new(@path)
        conn.results_as_hash = true
        # busy_handler_timeout (not busy_timeout): releases the GVL between
        # retries, so a thread waiting on another connection's write lock can't
        # starve the very thread that must finish to release it.
        conn.busy_handler_timeout = 5_000
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        conn
      end

      def enforce_max_events(session_id)
        max_events = limits.max_events_per_session
        return unless max_events

        total = db.get_first_value("SELECT COUNT(*) FROM events WHERE session_id = ?", [session_id])
        return unless total > max_events

        excess = total - max_events
        db.execute(
          "DELETE FROM events WHERE id IN (SELECT id FROM events WHERE session_id = ? ORDER BY timestamp ASC LIMIT ?)",
          [session_id, excess]
        )
      end

      def enforce_max_sessions(protected_session_id)
        max_sessions = limits.max_sessions
        return unless max_sessions

        total = db.get_first_value("SELECT COUNT(*) FROM sessions")
        return unless total > max_sessions

        to_evict = total - max_sessions
        oldest = db.execute(
          "SELECT session_id FROM sessions WHERE session_id != ? ORDER BY updated_at ASC LIMIT ?",
          [protected_session_id, to_evict]
        ).map { |session_row| session_row["session_id"] }

        oldest.each do |sid|
          db.execute("DELETE FROM events WHERE session_id = ?", [sid])
          db.execute("DELETE FROM sessions WHERE session_id = ?", [sid])
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

        total = db.get_first_value("SELECT COUNT(*) FROM problems")
        return unless total > max

        excess = total - max
        fps = db.execute("SELECT fingerprint FROM problems ORDER BY last_seen ASC LIMIT ?", [excess]).map { |r| r["fingerprint"] }
        fps.each do |fp|
          db.execute("DELETE FROM occurrences WHERE fingerprint = ?", [fp])
          db.execute("DELETE FROM problems WHERE fingerprint = ?", [fp])
        end
      end

      def enforce_max_server_events
        max = limits.max_server_events
        return unless max

        total = db.get_first_value("SELECT COUNT(*) FROM server_events")
        return unless total > max

        excess = total - max
        db.execute("DELETE FROM server_events WHERE id IN (SELECT id FROM server_events ORDER BY timestamp ASC LIMIT ?)", [excess])
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

      # File-backed stores are thread-safe via per-thread WAL connections (see
      # #db); in-memory stores share one connection, so their public ops
      # serialize through the reentrant @monitor (reentrant: save_occurrence
      # -> save_metadata). Wrap-all, defined last, so new methods stay
      # covered; the wrapper also applies utf8_arg to every argument.
      synchronized = public_instance_methods(false)
      prepend(Module.new do
        synchronized.each do |method_name|
          define_method(method_name) do |*args, **kwargs, &block|
            args = args.map { |arg| utf8_arg.call(arg) }
            kwargs = kwargs.transform_values { |value| utf8_arg.call(value) }
            if @in_memory
              @monitor.synchronize { super(*args, **kwargs, &block) }
            else
              super(*args, **kwargs, &block)
            end
          end
        end
      end)
    end
  end
end
