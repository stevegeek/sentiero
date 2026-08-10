# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0.beta3] - 2026-08-10

- The client error detail page shows the recorded JavaScript stack. A group
  keeps the first non-empty stack among its occurrences, so a masked
  "Script error." occurrence no longer hides the informative stack from a
  later one.
- The client error detail page labels the pages facet "Entry pages": the
  tallied values are session entry URLs, not the page where the error fired.

## [1.0.0.beta2] - 2026-08-03

- The SQLite store compresses event payloads at rest: rrweb payloads of 1 KB
  or more (FullSnapshots are ~93% of a production database's bytes) are
  stored as zlib BLOBs — a 5-7x size reduction on real data. Reads sniff the
  format per row, so mixed databases work; on first open of a pre-existing
  database, a one-time batched migration compresses old rows (guarded by
  `PRAGMA user_version`, so later opens skip the scan). Downgrading past
  this version afterwards is not supported. The migration frees pages but
  does not shrink the file — run `VACUUM` to reclaim disk.

## [1.0.0.beta1] - 2026-08-03

Initial release.

Changes since 1.0.0.alpha1:

- The sessions dashboard can filter by minimum session duration and minimum
  event count. `SessionStore#list_sessions` gains `min_duration_ms:` and
  `min_events:` keywords — custom store implementations must accept them.
- Large-snapshot flushes no longer get stuck retrying a 413: the recorder
  halves the batch until it fits (backing off if the server keeps rejecting)
  and drops a single event that still exceeds the cap with a distinct
  warning. The server-side ingest body cap is now configurable via
  `config.max_body_size` (default 512 KB). (#7)
- The replay page's scroll-depth badge rounds sub-pixel offsets. (#9)