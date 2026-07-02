---
title: Crystal & Marten
nav_order: 4
description: Report server-side exceptions and custom events from Crystal/Marten apps to Sentiero with the sentiero-cr shard.
---

# Crystal & Marten

[`sentiero-cr`](https://github.com/stevegeek/sentiero-cr) is a Crystal **reporter shard** that sends server-side **exceptions** and **custom events** from a Crystal or [Marten](https://martenframework.com) app to a Sentiero ingest over HTTP. It mirrors the Ruby gem's reporter concepts (`Sentiero::Reporter.notify` / `.track`, context, client-side scrubbing, fail-safe async delivery), plus an optional Marten middleware that auto-captures unhandled exceptions.

> **Scope:** this is the *reporter* only, for server-side error and event tracking. Browser **session recording** is done by the JavaScript recorder (see [The Recorder](/guide/recorder/)); there is no Crystal recorder. A Crystal app uses the shard to push its *server* exceptions/events into the same Sentiero project that its browser sessions report to.

## How it fits together

Sentiero's dashboard runs in the Ruby gem. A Crystal/Marten process can't mount the Ruby Rack dashboard in-process (separate runtimes), so the two coexist as **two processes behind one reverse proxy**, and to a visitor it looks like one site:

```
            ┌─────────────────────────┐        ┌─────────────────────────┐
  visitor ─►│  Marten app (Crystal)   │  HTTP  │  Sentiero (Ruby, Rack)  │
            │  + sentiero-cr shard  ──┼───────►│  ingest + dashboard     │
            └─────────────────────────┘        └─────────────────────────┘
```

The Crystal app never touches Sentiero's store directly. The shard POSTs to the Ruby ingest, and only Ruby writes the store. There is **zero cross-language schema coupling**: the only contract is the HTTP ingest protocol.

## Ruby side: accept ingest

On your Sentiero (Ruby) instance, define an ingest key and mount the ingest endpoints (alongside the dashboard):

```ruby
Sentiero.configure do |config|
  # Map a secret bearer key to a project name. The server derives the project
  # from the key, so the Crystal app never sends the project in the body.
  config.ingest_keys = { ENV["SENTIERO_INGEST_KEY"] => "my-app" }
end
```

```ruby
# Mount the ingest lanes the shard POSTs to (paths shown under /sentiero):
mount Sentiero::Web::ErrorsApp.new => "/sentiero/errors"   # exceptions
mount Sentiero::Web::TrackApp.new  => "/sentiero/track"    # custom events
mount Sentiero::Web::DashboardApp.new => "/sentiero"        # dashboard
```

See [Configuration](/guide/configuration/) for `ingest_keys` and [Error Tracking](/guide/error-tracking/) for how reported errors are fingerprinted and surfaced under `/issues`.

## Install the shard

```yaml
# shard.yml
dependencies:
  sentiero:
    github: stevegeek/sentiero-cr
```

```bash
shards install
```

## Configure the reporter

```crystal
require "sentiero"

Sentiero::Reporter.configure do |c|
  c.endpoint    = "https://sentiero.example.com/sentiero"  # base where errors/track are mounted
  c.ingest_key  = ENV["SENTIERO_INGEST_KEY"]               # per-project bearer key
  c.project     = "my-app"                                 # project identifier
  c.environment = "production"
  c.release     = "v1.2.3"                                 # optional release tag

  # Async delivery (default: true, max_queue 100, drop-on-full, never blocks the caller)
  c.async     = true
  c.max_queue = 200

  # HTTP timeouts (seconds)
  c.open_timeout = 2.0
  c.read_timeout = 3.0

  # Extra keys to scrub (defaults already cover password, token, secret, etc.)
  c.filter_keys = ["my_secret_field"]
end
```

`endpoint` is the base URL where the ingest lanes live; the shard appends `/errors` and `/track`.

## Report an exception

```crystal
begin
  do_something_risky
rescue ex
  Sentiero::Reporter.notify(ex)
end
```

With extra context and linkage to a browser session:

```crystal
Sentiero::Reporter.notify(
  ex,
  context:    {"user_id" => user.id.to_s, "plan" => "pro"},
  session_id: sid,   # links the exception to the Sentiero session replay
  window_id:  wid,
)
```

## Track a custom event

```crystal
Sentiero::Reporter.track(
  "signup",
  level:      "info",
  session_id: sid,
  payload:    {"plan" => "pro", "referrer" => "google"},
)
```

`notify` and `track` **never raise into the caller**; delivery errors are swallowed and logged to STDERR.

## Marten middleware (auto-capture)

`require "sentiero/marten"` and add the middleware to your settings. It catches unhandled exceptions, reads the session/window id cookies for linkage, reports to Sentiero, then re-raises so Marten's own error handling still fires:

```crystal
# config/settings/base.cr
require "sentiero/marten"

Marten.configure do |config|
  config.middleware = [
    # ... your existing middleware ...
    Sentiero::Reporter::Middleware,
  ]
end
```

### Linking server errors to browser sessions

The middleware reads two cookies, set by the Sentiero JavaScript recorder in the visitor's browser, to tie a server exception to the exact session replay:

| Cookie | Config key | Default |
|---|---|---|
| Session id | `c.session_cookie_name` | `"sentiero_sid"` |
| Window id  | `c.window_cookie_name`  | `"sentiero_wid"` |

(See [Privacy & Masking](/guide/privacy/#browser-storage--cookies) for what those cookies are.)

## Client-side scrubbing

Values whose key matches a sensitive pattern (case-insensitive substring such as `password`, `token`, `secret`, `authorization`, `api_key`, …) are replaced with `[FILTERED]` before the payload leaves the process. Add app-specific keys with `c.filter_keys`.

## Wire protocol

The shard speaks the same ingest protocol as the Ruby reporter:

- `POST <endpoint>/errors` for exception payloads
- `POST <endpoint>/track` for custom-event payloads
- `Authorization: Bearer <ingest_key>` on every request
- `project` is **not** sent in the body; the server derives it from the key

Because the contract is just HTTP, a Crystal app and a Ruby app can report into the **same** Sentiero project side by side.
