# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0.beta1] - ?

Initial release.

Changes since 1.0.0.alpha1:

- The sessions dashboard can filter by minimum session duration and minimum
  event count. `SessionStore#list_sessions` gains `min_duration_ms:` and
  `min_events:` keywords — custom store implementations must accept them.