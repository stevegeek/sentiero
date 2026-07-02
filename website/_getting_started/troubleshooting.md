---
title: Troubleshooting
nav_order: 4
description: Common reasons nothing is recording and how to fix them.
---

# Troubleshooting

## Nothing is recording at all

**Symptom:** Sessions never appear in the dashboard.

**Likely causes and fixes:**

- **Recorder script not injected.** Check page source for `<script id="sentiero-config">`. If it's missing, the layout helper isn't running. Confirm `sentiero_script_tag` (Rails/Roda) or `Sentiero::Web::ScriptTag.render` is called in the layout that's actually rendered for the page you're testing.

- **Wrong `events_url`.** The config JSON (`<script id="sentiero-config">`) contains `"eventsUrl"`. Check that it matches the path where `EventsApp` is mounted. Mismatch silently drops events; the browser POSTs to the wrong URL and gets a 404.

- **Events endpoint not mounted.** Verify the events route is mounted and reachable. A quick test:
  ```bash
  curl -X POST http://localhost:PORT/sentiero/events \
       -H "Content-Type: application/json" \
       -d '{"sessionId":"test","windowId":"test","events":[{"type":4,"timestamp":1}]}'
  ```
  A mounted, working endpoint returns `200 {"status":"ok"}`. A missing route returns `404`.

- **Store not configured.** `Sentiero.store` raises `Sentiero::Error` if `config.store` is `nil` and no default was set. The Rails engine auto-sets `Sentiero::Rails::Store.new`; other frameworks require an explicit `config.store =` in `Sentiero.configure`. Check your boot logs for an uncaught error on the first event POST.

## Events POST succeeds but dashboard shows nothing

**Symptom:** The events endpoint returns `200` but sessions never appear.

- **Route mount order.** In plain Rack `map` blocks, the dashboard mount (`map "/sentiero"`) must not shadow the events mount (`map "/sentiero/events"`). If both are present, order doesn't matter with `map`, but verify there's no catch-all intercepting requests first.

- **Store write silently failing.** Enable error logging and watch server output when an event batch is sent. If `save_events` raises, the batch is dropped.

## CORS errors in the browser console

**Symptom:** Browser console shows `CORS policy` errors on `POST /sentiero/events`.

The events endpoint enforces CORS using `config.cors_origins`. If the origin of your page is not in the list, the browser blocks the request.

Fix:

```ruby
Sentiero.configure do |config|
  config.cors_origins = ["https://yoursite.com"]
  # For local dev:
  # config.cors_origins = ["http://localhost:3000"]
end
```

`cors_origins = []` (the default) means no cross-origin requests are permitted. If the recorder and your app are on the same origin, CORS is not needed.

## GPC or opt-out silently suppressing recording

**Symptom:** Recording works for some users but not others, with no errors.

Two privacy mechanisms can suppress recording without any visible error:

- **Global Privacy Control (`respect_gpc`).** `config.respect_gpc` defaults to `true`. When the browser exposes `navigator.globalPrivacyControl === true`, the recorder does not start and no POST is sent to your server. This is intentional and correct.

- **End-user opt-out.** If `config.user_opt_out = true`, users who have called `window.Sentiero.optOut()` (or who have the opt-out cookie set) are not recorded. The cookie name defaults to `"sentiero_optout"`. Check browser cookies/localStorage for that key.

To rule these out in dev, temporarily set `config.respect_gpc = false` and clear the opt-out cookie.

## Dashboard returns 403 or a blank page

**Symptom:** `/sentiero` returns 403.

- `auth_callback` is returning falsy. Check that the callback receives the expected session/env state. The callback is called with the raw Rack `env` hash; inspect `env["rack.session"]` or whatever your auth mechanism populates. Exceptions in the callback are caught and treated as 403 (fail-closed).

- Route-level auth is rejecting the request before it reaches `DashboardApp`.

## Events are buffered but the dashboard lags

**Symptom:** Recording works, but sessions take a while to appear or show fewer events than expected.

For faster feedback in development, lower the flush settings (see [Configuration](/guide/configuration/) for defaults):

```ruby
Sentiero.configure do |config|
  config.flush_interval_ms = 2_000
  config.flush_event_threshold = 10
end
```

Don't set these too low in production; each flush is an HTTP request.

## Recorder JS 404

**Symptom:** The `<script src="...">` for the recorder returns 404.

- **The assets endpoint is not reachable.** There is no Rails engine asset pipeline for this. In Rails the recorder JS is served by `DashboardApp` itself, from its `/assets/*` route, which runs *before* the auth check (so assets stay public even when the dashboard is protected). In Roda/Rack, mount the standalone `Sentiero::Web::AssetsApp` explicitly at `/sentiero/assets` and call `r.sentiero_assets` (Roda) or `run Sentiero::Web::AssetsApp.new` inside the assets `map` block (Rack).

- **Route-level auth is shadowing the assets path (Rails).** If you wrapped the `DashboardApp` mount in a Devise `authenticate`/route constraint, that constraint also gates `/sentiero/assets/*`, so anonymous visitors get a 401/redirect on `recorder.js`. Either switch to `config.auth_callback`/`config.basic_auth` (assets short-circuit before the auth check) or mount `Sentiero::Web::AssetsApp` publicly outside the constraint. See [Authentication](/guide/authentication/).

- The recorder URL is being inferred from `events_url`. The asset filename is content-hashed (e.g. `recorder-TBGP22CQ.js`), so there is no stable un-hashed `recorder.js` to link directly. If you need to override it, pass the assets mount base as `recorder_url:` and let the manifest resolve the digested filename, for example `sentiero_script_tag(events_url: "/my/events", recorder_url: "/my/assets")`. The default inference handles this automatically when `events_url` follows the standard `/…/events` pattern.
