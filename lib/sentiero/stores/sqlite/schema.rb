# frozen_string_literal: true

module Sentiero
  module Stores
    class SQLite
      # Table/index definitions for the store's single SQLite3 connection.
      module Schema
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
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id TEXT NOT NULL,
              window_id TEXT NOT NULL,
              timestamp REAL,
              data TEXT NOT NULL
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
        end
      end
    end
  end
end
