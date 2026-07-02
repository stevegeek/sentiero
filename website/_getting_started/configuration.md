---
title: Configuration
nav_order: 3
description: All Sentiero configuration options and their defaults.
---

# Configuration

Sentiero is configured through `Sentiero.configure`, which yields a single `Sentiero::Configuration` object. Set options in an initializer (Rails) or once at boot (Roda/Sinatra/plain Rack):

```ruby
Sentiero.configure do |config|
  config.store = Sentiero::Stores::Redis.new
  config.capture_metadata = true
  config.retention_period = 90 * 24 * 60 * 60 # 90 days
end
```

This page is the authoritative reference for every option, grouped by area. Defaults match `lib/sentiero/configuration.rb`. Rails apps also have a separate `Sentiero::Rails.configure` object; see the [Rails section below](#rails-configuration).

> **Password masking is always enforced.** Regardless of any masking setting below (including `mask_all_inputs = false` or anything you pass via `mask_input_options` / `recorder_options`), password inputs are always masked. `Configuration::ENFORCED_PRIVACY` merges `{ maskInputOptions: { password: true } }` into every effective config and the frontend re-applies it independently. See [Privacy & Masking](/guide/privacy/).

## Core / Store

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `store` | Store instance | `nil` | The backend that persists sessions and events (Memory, File, SQLite, Redis, Rails AR, or a custom store). Required: reading `Sentiero.store` with this unset raises `Sentiero::Error`. The Rails engine auto-sets `Sentiero::Rails::Store.new` if you leave it `nil`. |
| `cors_origins` | Array of String | `[]` | Allowed origins for the public events endpoint. Empty means no cross-origin requests are permitted. |
| `auth_callback` | Proc / `nil` | `nil` | Proc called with the Rack env to authorize dashboard and analytics requests. Returns truthy to allow; a falsy return yields 403. `nil` means no callback-based auth (protect via route-level auth instead). |
| `basic_auth` | Hash / `nil` | `nil` | When set to `{ user: "...", password: "..." }`, enables the built-in `Sentiero::Web::BasicAuth` middleware, which performs constant-time HTTP Basic authentication before any dashboard route. `nil` disables it (use `auth_callback` or route-level auth instead). Assumes TLS terminated upstream. |
| `ingest_keys` | Hash | `{}` | Maps ingest secret keys to project names (e.g. `{ "secret123" => "myapp" }`). Used by `Sentiero::Web::IngestApp` to authenticate server-side error ingestion requests. Empty hash means no key-authenticated ingest is accepted. |

## Frontend Flush & Limits

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `flush_interval_ms` | Integer | `10_000` | Milliseconds between time-based flushes from the browser to the server. |
| `flush_event_threshold` | Integer | `50` | Buffer size that triggers an immediate flush, whichever comes first with the interval. |
| `max_events_per_page` | Integer | `1_000` | Pagination cap for events returned by the dashboard events API per page. |
| `max_events_per_request` | Integer / `nil` | `nil` | Optional ceiling on events accepted in a single ingest request. `nil` = no extra cap (the server payload size limit still applies). |
| `max_sessions` | Integer / `nil` | `nil` | LRU cap on total stored sessions. `nil` = unlimited. When exceeded, the oldest sessions (by `updated_at`) are evicted. |
| `max_events_per_session` | Integer / `nil` | `nil` | LRU cap on events kept per session. `nil` = unlimited. When exceeded, the oldest events (by timestamp) are evicted. |
| `cross_tab_sessions` | Boolean | `true` | `true` stores the session ID in `localStorage` (shared across tabs); `false` uses `sessionStorage` (per-tab). See [Privacy & Masking](/guide/privacy/). |
| `session_idle_timeout` | Integer | `21_600` (6 hours) | Inactivity gap in seconds after which a returning visitor gets a fresh session ID. Bounds a "journey" without splitting it on short breaks. |
| `session_max_age` | Integer | `604_800` (7 days) | Absolute lifetime cap in seconds for one session ID, even for continuously active tabs — keeps the identifier from becoming permanent and lets retention purge age data out. |

## Capture Toggles

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `capture_metadata` | Boolean | `false` | Capture page URL, referrer, user agent, and viewport with the session. |
| `capture_errors` | Boolean | `false` | Capture JS errors and unhandled promise rejections as timeline custom events. |
| `capture_web_vitals` | Boolean | `false` | Capture Core Web Vitals (LCP, CLS, INP, etc.) and surface them as badges in replay. |
| `capture_clicks` | Boolean | `false` | Record click positions for the click overlay in replay and the analytics click heatmaps. |
| `track_navigation` | Boolean | `false` | Log outbound link clicks as `navigation` custom events. |
| `track_custom_events` | Boolean | `false` | Enable declarative `data-sentiero-track-*` attribute tracking. See [Custom Events](/guide/custom-events/). |
| `track_forms` | Boolean | `false` | Capture real form submits as `__form_submit` custom events (form `name`/`id` attributes + page URL, never values) for the form analytics view. |

## Recorder / Privacy Masking

These map to rrweb recorder options, converted from snake_case to camelCase automatically. See [The Recorder](/guide/recorder/) and [Privacy & Masking](/guide/privacy/) for behavior detail.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `mask_all_inputs` | Boolean | `true` | Mask all form input values. Passwords stay masked even when this is `false`. |
| `mask_input_options` | Hash | `{}` | Per-input-type masking (e.g. `{ email: true }`). `{ password: true }` is always merged in and cannot be overridden. |
| `block_selector` | String | `"[data-rr-block]"` | CSS selector for elements excluded from recording entirely. |
| `mask_text_selector` | String | `"[data-rr-mask]"` | CSS selector for elements whose text content is masked. |
| `ignore_selector` | String | `"[data-rr-ignore]"` | CSS selector for elements whose DOM mutations are ignored. |
| `sampling` | Hash | `{ scroll: 150, input: "last" }` | rrweb throttling: scroll interval in ms and input sampling strategy. |
| `inline_stylesheet` | Boolean / `nil` | `nil` | Forwarded to rrweb as `inlineStylesheet` only when set; omitted when `nil`. |
| `checkout_every_n_ms` | Integer / `nil` | `nil` | Forwarded to rrweb as `checkoutEveryNms` only when set; omitted when `nil`. Forces a full snapshot on the given interval. |
| `recorder_options` | Hash | `{}` | Escape hatch: a raw camelCase hash passed through to rrweb verbatim. First-class options above take precedence on overlapping keys. |

## Error Tracking / Resource Limits

These options cap stored error-tracking data. All default to the values shown; set them lower for resource-constrained deployments.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `max_problems` | Integer / `nil` | `5_000` | LRU cap on stored problems (grouped error fingerprints). When exceeded, problems with the oldest `last_seen` are evicted along with their occurrences. |
| `max_server_events` | Integer / `nil` | `50_000` | LRU cap on stored server events. When exceeded, the oldest events (by timestamp) are evicted. |

## Analytics

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `analytics_max_scan_sessions` | Integer | `5000` | Cap on how many sessions a single compute-on-read analytics scan (or bulk erase/purge batch) reads. Bounds memory and request time at scale. |

## Sharing

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `shareable_replays` | Boolean | `false` | Enables the standalone-HTML export and play-from-JSON import routes. Off by default because a share file is a full session dump that leaves your infrastructure; the routes 404 until enabled. |

## Privacy & Compliance

See [Privacy & Masking](/guide/privacy/) for the full guide.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `user_opt_out` | Boolean | `false` | Honor an end-user opt-out cookie. When `true`, requests carrying the opt-out cookie are not recorded. |
| `opt_out_cookie_name` | String | `"sentiero_optout"` | Name of the cookie that signals end-user opt-out. |
| `respect_gpc` | Boolean | `true` | Honor the browser's Global Privacy Control signal (`navigator.globalPrivacyControl`) as an opt-out. Enforced client-side; no POST is sent when the signal is set. |
| `retention_period` | Integer (seconds) / `nil` | `nil` | Drives `Sentiero.purge_expired!`. `nil` keeps data forever; set a value (in seconds) and run the purge from a scheduler / `rake sentiero:purge`. Purge is destructive and irreversible. |
| `redaction` | Config object | (see below) | Side-channel redaction engine: URL stripping/filtering, free-text pattern redaction, and opt-in DOM text backstop. See [`config.redaction`](#configredaction) below. |
| `anonymize_ip` | Boolean | `true` | Truncate client IPs before they reach the store or logs (IPv4 `/24`, IPv6 `/48`) via `Sentiero::IpAnonymizer`. |
| `audit_log` | Proc / `nil` | `nil` | Hook invoked for auditable dashboard/analytics actions (session listing/viewing, export, etc.). A no-op when unset; a raising callback is caught and logged. |

### config.redaction

Configures the side-channel redaction engine. All settings are optional; the defaults are secure out of the box. See [Side-channel redaction](/guide/privacy/#side-channel-redaction) for the full reference.

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `url_mode` | Symbol | `:strip` | `:strip` keeps path, drops query and fragment. `:keep_filtered` filters params. `:keep_all` is verbatim. |
| `url_param_allowlist` | Array of String | `[]` | Params kept verbatim in `:keep_filtered` mode (e.g. `%w[utm_source gclid]`). |
| `url_param_denylist` | Array of String | `[]` | Extra params to drop in `:keep_filtered` mode. Augments the built-in sensitive-name list. |
| `disabled_patterns` | Array of Symbol | `[]` | Built-in free-text patterns to skip. Choices: `:email`, `:url`, `:jwt`, `:long_hex`, `:card`. |
| `custom_patterns` | Array of Regexp | `[]` | Additional patterns. Applied to side-channel text and, when set, to DOM text. |
| `dom_patterns` | Array of Symbol | `[]` | Built-in patterns to apply to rrweb DOM text/data fields (opt-in server-side backstop). |
| `server_proc` | Proc / `nil` | `nil` | Ruby-only hook run on ingest after the declarative engine. Fail-closed: a raising proc drops the event. |

Minimal example:

```ruby
Sentiero.configure do |config|
  config.redaction.url_mode            = :keep_filtered
  config.redaction.url_param_allowlist = %w[utm_source utm_medium gclid]
  config.redaction.custom_patterns     = [/\bACCT-\d{6}\b/]
end
```

## Rails Configuration

Rails apps have a second, separate configuration object, `Sentiero::Rails.configuration` (set via `Sentiero::Rails.configure`). It is distinct from `Sentiero.configuration` above. Source: `lib/sentiero/rails/configuration.rb`.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `events_url` | String | `"/sentiero/events"` | Default ingest endpoint the `sentiero_script_tag` view helper points the recorder at. Passing `events_url:` directly to the helper overrides it. |
| `reporter_middleware` | Boolean | `true` | When `true`, the engine auto-inserts `Sentiero::Reporter::Middleware` into the Rails middleware stack (mirrors Sentry/Honeybadger auto-install). The middleware only activates if the reporter is also configured and active. Set to `false` to opt out of automatic insertion and manage the middleware manually. |

```ruby
Sentiero::Rails.configure do |config|
  config.events_url = "/sentiero/events" # default
  config.reporter_middleware = true       # default; set false to opt out
end
```

See [Rails](/guide/rails/) for the full Rails integration guide.
