---
title: Storage Backends
nav_order: 1
description: Pluggable storage, memory, file, SQLite, Redis, and ActiveRecord backends.
---

# Storage Backends

Sentiero ships five storage backends: **memory**, **file**, **SQLite**, **Redis**, and **ActiveRecord** (via `sentiero-rails`). All implement the same `Sentiero::Store` interface.

## Store Interface

All storage backends extend `Sentiero::Store`. Session replay requires six methods. The base class also provides `each_session_events` and `purge_older_than` (built on the six, override only for efficiency) plus a no-op `save_metadata`, so a backend that implements the six is complete. Error tracking adds eleven more methods (see [Custom Stores](#custom-stores)).

Option defaults and the full configuration reference live in [Configuration](/guide/configuration/); this page documents store mechanics.

Window-level methods take a `Sentiero::WindowRef` -- an immutable value object
(`Sentiero::WindowRef = Data.define(:session_id, :window_id)`) that addresses a
single window via its `(session_id, window_id)` pair. Session-level methods
(`get_session`, `delete_session`, `save_metadata`) take a bare `session_id`
string, since a lone id is not a window address.

```ruby
ref = Sentiero::WindowRef.new("session-1", "window-1")
store.save_events(ref, events)
store.get_events(ref)
```

### Required Methods

| Method | Description |
|--------|-------------|
| `save_events(ref, events)` | Persist an array of rrweb event hashes for the window addressed by `ref`. Must handle `nil` and `[]` as no-ops. |
| `list_sessions(limit:, offset:, since:, until_time:, sort_by:, search:)` | Return session summaries, newest first by default. Supports pagination, date range filtering, sort (`"created_at"`, `"event_count"`, or default `"updated_at"`), and search (matches session ID and metadata values). |
| `get_session(session_id)` | Return a single session hash with `:windows` array, timestamps, and metadata. `nil` if not found. |
| `get_events(ref, after:, limit:)` | Return events for the window addressed by `ref`, ordered by timestamp. `after:` is an exclusive timestamp cursor. Returns `[]` if nothing matches. |
| `delete_session(session_id)` | Remove session and all its windows/events. Must not raise for nonexistent sessions. |
| `delete_window(ref)` | Remove the single window addressed by `ref`. If it was the last window, remove the session too. Must not raise for nonexistent windows. |

### Optional Methods

These have default implementations in the base class. Override for efficiency.

| Method | Default Behavior |
|--------|-----------------|
| `save_metadata(session_id, metadata)` | No-op. When implemented, merges a hash of metadata (URL, user agent, viewport, etc.) into the session. |

### Return Shapes

Session summary (from `list_sessions`):

```ruby
{
  session_id: "abc-123",
  window_ids: ["w1", "w2"],
  event_count: 42,
  created_at: 1718000000.0,   # Float (epoch seconds)
  updated_at: 1718003600.0,
  first_event_at: 1718000000.0,
  last_event_at: 1718003600.0,
  metadata: { "url" => "..." }  # present only if metadata was saved
}
```

Session detail (from `get_session`):

```ruby
{
  session_id: "abc-123",
  windows: [
    { window_id: "w1", event_count: 30, first_event_at: 1000.0, last_event_at: 5000.0 },
    { window_id: "w2", event_count: 12, first_event_at: 2000.0, last_event_at: 6000.0 }
  ],
  created_at: 1718000000.0,
  updated_at: 1718003600.0,
  first_event_at: 1000.0,
  last_event_at: 6000.0,
  metadata: { "url" => "..." }
}
```

## Memory Store

In-memory storage backed by `concurrent-ruby` primitives (`Concurrent::Map`, `Concurrent::Array`). Thread-safe for multi-threaded web servers.

**Use for:** development, testing. Data is lost on process restart.

```ruby
Sentiero.configure do |config|
  config.store = Sentiero::Stores::Memory.new
end
```

No dependencies beyond `concurrent-ruby` (a runtime dependency of the gem).

The Memory, File, and SQLite stores expose `store.clear!` to wipe all data (useful in test setup). The Redis and ActiveRecord stores do not.

## File Store

File-based storage that persists sessions as a directory tree. Each session gets a directory containing a `meta.json` file and one `.jsonl` file per window (one JSON event per line).

**Use for:** development, small single-process deployments. Data persists across restarts. NOT suitable for high-concurrency production.

```ruby
require "sentiero/stores/file"

Sentiero.configure do |config|
  config.store = Sentiero::Stores::File.new(path: "tmp/sentiero_sessions")
end
```

### Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `path` | `String` | (required) | Directory path for session data. Created automatically if it doesn't exist. |

### Directory Structure

```
tmp/sentiero_sessions/
  {session_id}/
    meta.json         # timestamps, metadata
    {window_id}.jsonl  # one JSON event per line
```

## SQLite Store

SQLite-backed storage using a single database file. Uses WAL journal mode for better concurrency. No external services required.

**Use for:** single-server production, small deployments, development with persistence.

```ruby
require "sentiero/stores/sqlite"

Sentiero.configure do |config|
  config.store = Sentiero::Stores::SQLite.new(path: "sentiero.db")
end
```

### Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `path` | `String` | `"sentiero.db"` | Database file path. Use `":memory:"` for in-memory database. |

If the `sqlite3` gem is not in your bundle, the require raises `LoadError` with an explanatory message.

### Schema

Five tables, created automatically on initialization:

| Table | Purpose |
|-------|---------|
| `sessions` | One row per session. Columns: `session_id` (unique), `created_at`, `updated_at`, `first_event_at`, `last_event_at`, `metadata` (JSON text). |
| `events` | One row per rrweb event. Columns: `session_id`, `window_id`, `timestamp` (real), `data` (JSON text). Indexed on `(session_id, window_id, timestamp)`. |
| `problems` | One row per grouped error fingerprint. Columns: `fingerprint` (unique), `project`, `exception_class`, `title`, `message`, `count`, `status`, `first_seen`, `last_seen`, `resolved_at`. |
| `occurrences` | One row per individual error occurrence. Columns: `occurrence_id`, `fingerprint`, `session_id`, `timestamp`, `data` (JSON text). Indexed on `(fingerprint, timestamp)` and `session_id`. |
| `server_events` | One row per server-side event. Columns: `event_id`, `project`, `name`, `level`, `session_id`, `timestamp`, `data` (JSON text). |

Enforces `max_events_per_session` and `max_sessions` by LRU eviction (oldest `updated_at`). Also enforces `max_problems` (LRU by `last_seen`) and `max_server_events` (oldest by timestamp). The session currently being written is protected from eviction.

## Redis Store

Production-ready store using Redis sorted sets, hashes, and sets. Requires the `redis` gem.

```ruby
require "sentiero/stores/redis"

Sentiero.configure do |config|
  config.store = Sentiero::Stores::Redis.new(
    redis: Redis.new(url: ENV["REDIS_URL"]),
    ttl: 86_400 * 7,
    prefix: "myapp:sentiero:"
  )
end
```

### Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `redis` | `::Redis` | (required) | A connected Redis client instance |
| `ttl` | `Integer` / `nil` | `nil` | TTL in seconds applied to all keys. `nil` = no expiry. |
| `prefix` | `String` | `"sentiero:"` | Key namespace prefix for all Redis keys |

If the `redis` gem is not in your bundle, the require raises `LoadError` with an explanatory message.

### Redis Data Structures

| Key pattern | Type | Contents |
|-------------|------|----------|
| `{prefix}sessions` | Sorted set | Session IDs scored by `updated_at` |
| `{prefix}session:{id}` | Hash | Session metadata: `created_at`, `updated_at`, `first_event_at`, `last_event_at`, `metadata` (JSON) |
| `{prefix}windows:{id}` | Set | Window IDs belonging to the session |
| `{prefix}events:{session_id}:{window_id}` | Sorted set | Event JSON members scored by timestamp |

Timestamp updates (`first_event_at` / `last_event_at`) use an atomic Lua script to avoid race conditions.

When `ttl` is set, every key touched during `save_events` gets `EXPIRE` called. This means active sessions auto-renew; idle sessions expire.

## ActiveRecord store

The `sentiero-rails` gem provides `Sentiero::Rails::Store`, an ActiveRecord-backed store. It is set as the default store automatically when the Rails engine loads (if no store is already configured), so most Rails apps never instantiate it by hand.

Installation (add the gem, run the generator, migrate) is covered by the [Rails guide](/guide/rails/) and [Quick start](/guide/quick-start/). Storage-specific configuration is limited to the resource limits below; they are read from `Sentiero.configuration`, the same as every other store.

### Tables

The generator migration creates five tables.

| Table | Purpose |
|-------|---------|
| `sentiero_sessions` | One row per session. Columns: `session_id` (`string`, not null, unique index), `metadata` (`json`), `created_at`/`updated_at` (`t.timestamps`). |
| `sentiero_events` | One row per rrweb event. Columns: `session_id` (`string`, not null), `window_id` (`string`, not null), `timestamp` (`float`), `data` (`json`), `created_at` (`datetime`, not null). Composite index on `(session_id, window_id, timestamp)`, plus a `session_id` index; foreign key on `session_id` to `sentiero_sessions.session_id` (`on_delete: :cascade`). |
| `sentiero_problems` | One row per grouped error fingerprint. Columns: `fingerprint` (`string`, not null, unique index), `project` (not null), `exception_class` (not null), `title` (not null), `message`, `count` (`integer`, not null, default `0`), `status` (`string`, not null, default `"open"`, CHECK constraint `open`/`resolved`/`ignored`), `first_seen` (`float`, not null), `last_seen` (`float`, not null), `resolved_at` (`float`). Indexed on `project`, `status`, and `last_seen`. |
| `sentiero_occurrences` | One row per individual error occurrence. Columns: `occurrence_id` (`string`, not null, unique index), `fingerprint` (`string`, not null), `session_id` (`string`), `timestamp` (`float`, not null), `data` (`json`, not null). Composite index on `(fingerprint, timestamp)`, plus a `session_id` index. |
| `sentiero_server_events` | One row per server-side event. Columns: `event_id` (`string`, not null, unique index), `project` (not null), `name` (not null), `level`, `session_id`, `timestamp` (`float`, not null), `data` (`json`, not null). Indexed on `project` and `session_id`. |

The store uses `insert_all` for bulk event insertion and wraps writes in transactions. Eviction uses LRU by `updated_at` (see [Resource Limits](#resource-limits) below).

## Custom Stores

Subclass `Sentiero::Store` and implement the six required session methods. The
three window-level methods receive a `Sentiero::WindowRef` (destructure with
`ref.session_id` / `ref.window_id`); the base class provides
`validate_window_ref!(ref)` to validate both ids at once:

```ruby
class MyStore < Sentiero::Store
  def save_events(ref, events) = ...
  def list_sessions(limit:, offset: 0, since: nil, until_time: nil, sort_by: nil, search: nil) = ...
  def get_session(session_id) = ...
  def get_events(ref, after: nil, limit: nil) = ...
  def delete_session(session_id) = ...
  def delete_window(ref) = ...
end
```

Optionally override `save_metadata` if your backend can handle it efficiently.

### Error Tracking Methods

The six methods above cover session replay. To also serve as an error-tracking
backend (problems, occurrences, server events, everything the errors
dashboard reads), implement the eleven error-tracking methods:

```ruby
def save_occurrence(occurrence) = ...
def list_problems(project:, limit:, offset: 0, status: nil, sort_by: nil, search: nil, since: nil, until_time: nil) = ...
def get_problem(problem_id) = ...
def get_occurrences(problem_id, after: nil, limit: nil) = ...
def update_problem_status(problem_id, status) = ...
def save_server_event(event) = ...
def list_server_events(project:, limit:, name: nil, level: nil, session_id: nil, after: nil) = ...
def get_server_event(event_id) = ...
def occurrences_for_session(session_id, limit: nil) = ...
def server_events_for_session(session_id, limit: nil) = ...
def session_ids_for_problem(problem_id, limit: nil) = ...
```

`count_occurrences(problem_id, after: nil)` has a default implementation built
on `get_occurrences`; override it with a direct count (`ZCOUNT`,
`SELECT COUNT(*)`, ...) if your backend can count without materializing rows.

**Keying convention:** raw stored records (events, occurrences, server events)
are string-keyed hashes, exactly as they arrived from JSON; computed summaries
(sessions, problems) are symbol-keyed. See the comments in
`lib/sentiero/store.rb` for the exact return shapes.

### Contract Tests

Sentiero ships shared test modules that exercise the store interface. Include
them and implement one factory method:

```ruby
require "test_helper"
require "store_contract_tests"
require "error_store_contract_tests"

class MyStoreTest < Minitest::Test
  include StoreContractTests
  include ErrorStoreContractTests # only if you implement error tracking

  def create_store
    MyStore.new
  end
end
```

`StoreContractTests` runs ~40 tests covering: save/retrieve events, pagination, cursor-based queries, multi-window sessions, delete cascading, metadata merge, search, sort, date filtering, stats, and timestamp range tracking.

`ErrorStoreContractTests` adds the error-tracking coverage: problem upsert and reopen-on-resolved, list filters/sorts/pagination, occurrence cursors and counts, server events, session linkage, GDPR erasure, and retention purges.

A store passing `StoreContractTests` is a valid drop-in for session replay; passing `ErrorStoreContractTests` as well makes it a drop-in for the full error-tracking dashboard.

## Resource Limits

Three configuration options control storage growth. All default to `nil` (unlimited).

```ruby
Sentiero.configure do |config|
  config.max_sessions = 10_000
  config.max_events_per_session = 50_000
  config.max_events_per_request = 500
end
```

| Option | Scope | Eviction Strategy |
|--------|-------|-------------------|
| `max_sessions` | Total sessions in the store | LRU -- oldest by `updated_at` are evicted first. The session currently being written is protected from eviction. |
| `max_events_per_session` | Events per session, across all windows | Oldest events (by timestamp) are dropped first, starting from the earliest window. |
| `max_events_per_request` | Events accepted in a single `POST` to the events endpoint | Excess events are rejected (not stored). This is enforced in `EventsApp`, not the store. |

Eviction runs inline after each `save_events` call. Every built-in store implements `max_sessions` and `max_events_per_session` enforcement. Custom stores should do the same -- the limits are read from `Sentiero.configuration` within the store's `save_events` method.

### How Eviction Works per Store

**Memory:** Iterates `Concurrent::Map` entries sorted by `updated_at`, deletes the oldest. Event trimming shifts from the front of `Concurrent::Array` per window.

**File:** Reads `meta.json` timestamps to find oldest sessions, removes their directories. Event trimming rewrites `.jsonl` files with oldest lines removed.

**SQLite:** Queries for the oldest sessions by `updated_at` within a transaction, deletes their events and session rows. Event trimming deletes the oldest event rows by timestamp. The session currently being written is protected from eviction.

**Redis:** Not implemented at the store level. Use the `ttl` parameter for automatic key expiry. For hard session caps, combine `ttl` with application-level cleanup.

**ActiveRecord:** Queries for the oldest sessions by `updated_at`, deletes their events and session rows in a transaction. Event trimming queries for the oldest event IDs and bulk-deletes them.

## Storage footprint

How much disk or memory will recording cost? Here are real numbers from the bundled demo app (a small Roda todo list) using the File store, which keeps events as uncompressed JSON:

- About 137 KB per session at rest on average, roughly 1.9 KB per recorded event.
- Observed range: about 30 KB for a very short session to about 260 KB for an active multi-minute session.
- gzip compressed this sample corpus by roughly 14x (about 10 KB per session compressed).

A rough worked example: at ~140 KB per session, 10,000 sessions is about 1.4 GB at rest before any compression or retention.

Honest caveats before you size on these figures:

- The demo has a tiny, simple DOM. Real applications, especially complex SPAs with large DOMs, frequent mutations, or long sessions, can be several times larger per session. Treat the demo numbers as a rough floor and benchmark your own app.
- All built-in stores keep event payloads as JSON and do **not** compress at rest. The ~14x gzip figure is what you would save with database or disk level compression, or what travels compressed over the wire (the recorder gzips event payloads before sending them). Size your storage against the uncompressed numbers above.

To bound growth, use the controls in [Resource Limits](#resource-limits) above (`max_sessions`, `max_events_per_session`), the Redis `ttl` parameter, and `retention_period` (which drives `Sentiero.purge_expired!`). See [Configuration](/guide/configuration/) for the full reference on each.
