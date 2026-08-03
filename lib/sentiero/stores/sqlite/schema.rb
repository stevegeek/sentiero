# frozen_string_literal: true

module Sentiero
  module Stores
    class SQLite
      # Table/index definitions for the store's SQLite connections.
      module Schema
        # The events.type column (denormalized rrweb event type) sits BEFORE
        # the data blob on purpose: SQLite reads record columns left to right,
        # so a typed scan can check `type` without ever touching the (often
        # multi-page overflow) data payload of non-matching rows.
        EVENTS_COLUMNS = <<~SQL
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT NOT NULL,
          window_id TEXT NOT NULL,
          timestamp REAL,
          type INTEGER,
          data TEXT NOT NULL
        SQL

        def self.create(db)
          db.execute_batch(<<~SQL)
            CREATE TABLE IF NOT EXISTS sessions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id TEXT NOT NULL UNIQUE,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL,
              first_event_at REAL,
              last_event_at REAL,
              metadata TEXT
            );

            CREATE INDEX IF NOT EXISTS idx_sessions_session_id ON sessions(session_id);
            CREATE INDEX IF NOT EXISTS idx_sessions_updated_at ON sessions(updated_at);

            CREATE TABLE IF NOT EXISTS events (
              #{EVENTS_COLUMNS}
            );

            CREATE INDEX IF NOT EXISTS idx_events_session_window_ts ON events(session_id, window_id, timestamp);

            CREATE TABLE IF NOT EXISTS problems (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              fingerprint TEXT NOT NULL UNIQUE,
              project TEXT NOT NULL,
              exception_class TEXT NOT NULL,
              title TEXT NOT NULL,
              message TEXT,
              count INTEGER NOT NULL,
              status TEXT NOT NULL,
              first_seen REAL NOT NULL,
              last_seen REAL NOT NULL,
              resolved_at REAL
            );
            CREATE INDEX IF NOT EXISTS idx_problems_project ON problems(project);
            CREATE INDEX IF NOT EXISTS idx_problems_status ON problems(status);
            CREATE INDEX IF NOT EXISTS idx_problems_last_seen ON problems(last_seen);

            CREATE TABLE IF NOT EXISTS occurrences (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              occurrence_id TEXT NOT NULL,
              fingerprint TEXT NOT NULL,
              session_id TEXT,
              timestamp REAL NOT NULL,
              data TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_occurrences_fp_ts ON occurrences(fingerprint, timestamp);
            CREATE INDEX IF NOT EXISTS idx_occurrences_session ON occurrences(session_id);

            CREATE TABLE IF NOT EXISTS server_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              event_id TEXT NOT NULL,
              project TEXT NOT NULL,
              name TEXT NOT NULL,
              level TEXT,
              session_id TEXT,
              timestamp REAL NOT NULL,
              data TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_server_events_event_id ON server_events(event_id);
            CREATE INDEX IF NOT EXISTS idx_server_events_project ON server_events(project);
            CREATE INDEX IF NOT EXISTS idx_server_events_session ON server_events(session_id);
          SQL

          migrate_events_type!(db)
          migrate_compress_payloads!(db)
        end

        # Databases created before the events.type column existed get a
        # one-time table rebuild (not ALTER ADD COLUMN — that would append
        # type AFTER the data blob, defeating the column-order optimization
        # above). Backfills type from each row's JSON payload.
        def self.migrate_events_type!(db)
          columns = db.execute("PRAGMA table_info(events)").map { |row| row["name"] }
          return if columns.include?("type")

          db.transaction(:immediate) do
            db.execute_batch(<<~SQL)
              CREATE TABLE events_migrated (
                #{EVENTS_COLUMNS}
              );
              INSERT INTO events_migrated (id, session_id, window_id, timestamp, type, data)
                SELECT id, session_id, window_id, timestamp,
                       CASE WHEN json_type(data, '$.type') = 'integer'
                            THEN json_extract(data, '$.type') END,
                       data
                FROM events;
              DROP TABLE events;
              ALTER TABLE events_migrated RENAME TO events;
              CREATE INDEX idx_events_session_window_ts ON events(session_id, window_id, timestamp);
            SQL
          end
        end

        # user_version 1 = every large payload is zlib-compressed (PayloadCodec).
        SCHEMA_VERSION = 1

        # One-time pass compressing pre-existing plain-TEXT payloads. Batched
        # in short transactions so a live recorder's ingest writes interleave
        # instead of timing out behind one giant lock. Guarded by
        # PRAGMA user_version, so subsequent opens skip the table scan.
        # Frees pages for reuse but does not shrink the file — VACUUM manually
        # to reclaim disk.
        def self.migrate_compress_payloads!(db)
          return if db.get_first_value("PRAGMA user_version").to_i >= SCHEMA_VERSION

          loop do
            rows = db.execute(
              "SELECT id, data FROM events WHERE typeof(data) = 'text' AND LENGTH(data) >= ? LIMIT 500",
              [PayloadCodec::COMPRESSION_THRESHOLD]
            )
            break if rows.empty?

            db.transaction(:immediate) do
              rows.each do |row|
                db.execute("UPDATE events SET data = ? WHERE id = ?", [PayloadCodec.encode(row["data"]), row["id"]])
              end
            end
          end
          db.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
        end
      end
    end
  end
end
