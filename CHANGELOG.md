# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Large-snapshot flushes no longer get stuck retrying a 413: the recorder
  halves the batch until it fits (keeping the learned cap for later flushes)
  and drops a single event that still exceeds the cap with a distinct
  warning. The server-side ingest body cap is now configurable via
  `config.max_body_size` (default 512 KB). (#7)

## [1.0.0.beta1] - 2026-08-03

Initial release.

Changes since 1.0.0.alpha1:

- The sessions dashboard can filter by minimum session duration and minimum
  event count. `SessionStore#list_sessions` gains `min_duration_ms:` and
  `min_events:` keywords — custom store implementations must accept them.