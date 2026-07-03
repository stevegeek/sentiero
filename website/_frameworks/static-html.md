---
title: Plain HTML / Static Sites
nav_order: 5
description: Recording static HTML pages (hand-written, Jekyll, Bridgetown, or any non-Ruby backend) with a self-hosted Sentiero instance.
---

# Plain HTML / Static Sites

The recorder is plain JavaScript — it doesn't need a Ruby backend on the pages it records. Any static page (hand-written HTML, a Jekyll/Bridgetown build, a site served by Caddy or nginx) can record sessions into a Sentiero instance you host elsewhere, as long as the browser can reach Sentiero's events endpoint.

This guide assumes Sentiero is mounted under `/sentiero/` on the same origin as your pages (see [Sinatra / Rack](/guide/sinatra/) for mounting). For a different origin, add your site to `config.cors_origins` on the Sentiero side.

## The simplest integration: one script tag

Sentiero serves the recorder bundle at a **stable URL**, `<dashboard mount>/recorder.js`, as a sibling of the events endpoint. With the standard mount that means one tag before `</body>` and no configuration at all:

```html
<script src="/sentiero/recorder.js"></script>
```

When there is no config block, the recorder derives the events endpoint from its own URL by swapping the last path segment for `events` — `/sentiero/recorder.js` → `/sentiero/events`. With the standard mount (`map("/sentiero/events")` + `map("/sentiero")`), that's exactly right.

> **Don't use the hashed asset URL for this.** The same derivation applied to `/sentiero/assets/recorder-XXXX.js` yields `/sentiero/assets/events`, which doesn't exist. If you load the recorder from `/assets/`, you must provide a config block (below).

## Configuring: the two-tag snippet

To set any option, add a JSON config block with the id `sentiero-config`. The recorder auto-boots from it — no init call needed:

```html
<script type="application/json" id="sentiero-config">
  {"eventsUrl": "/sentiero/events", "captureClicks": true}
</script>
<script src="/sentiero/recorder.js"></script>
```

This is exactly what the Ruby `ScriptTag.render` helper emits — two tags, nothing framework-specific.

`eventsUrl` is the **only required key**. When a config block is present the URL derivation described above is skipped, so `eventsUrl` must be set. Everything else has client-side defaults.

## Configuration reference

| Key | Type | Default | What it does |
|-----|------|---------|--------------|
| `eventsUrl` | string | — (required) | Endpoint the recorder POSTs event batches to. |
| `flushIntervalMs` | number | `10000` | Flush the buffer every N ms. |
| `flushEventThreshold` | number | `50` | Flush early once N events are buffered. |
| `crossTabSessions` | boolean | `true` | Share one session id across tabs. |
| `sessionIdleTimeoutMs` | number | `21600000` (6h) | Start a new session after this much inactivity. |
| `sessionMaxAgeMs` | number | `604800000` (7d) | Hard cap on a session's age. |
| `recorderOptions` | object | `{}` | Options passed to rrweb. Privacy defaults are merged in: `maskAllInputs: true`, and password masking cannot be disabled. |
| `redaction` | object | built-in defaults | Client-side redaction rules; matches the server's `config.redaction.to_client_hash`. |
| `captureClicks` | boolean | `false` | Record click events for heatmaps/frustration analytics. |
| `trackNavigation` | boolean | `false` | Record page navigations. |
| `trackForms` | boolean | `false` | Record form submissions (redacted). |
| `captureErrors` | boolean | `false` | Capture JS errors into the session timeline. |
| `captureWebVitals` | boolean | `false` | Capture Core Web Vitals. |
| `captureMetadata` | boolean | `false` | Send page metadata (URL, referrer, viewport) with batches. |
| `trackCustomEvents` | boolean | `false` | Track events declared via `data-sentiero-track-*` element attributes. |
| `optOutCookieName` | string | unset | Cookie name checked for user opt-out. |
| `respectGpc` | boolean | `false` | Don't record visitors sending the Global Privacy Control signal. |

The booleans mirror the Ruby `Sentiero.configure` flags (`capture_clicks`, `track_navigation`, …) — the Ruby helper just serializes them into this same JSON block.

## Alternative: resolving the hashed bundle from the manifest

The `/recorder.js` alias is served with a short cache (5 minutes) so upgrades roll out quickly. If you'd rather serve the immutably-cached, content-hashed bundle (`/sentiero/assets/recorder-XXXX.js`), don't hardcode the hash — it changes on every build. `manifest.json` is public and maps logical names to hashed filenames, so a tiny loader stays correct across upgrades:

```html
<script type="application/json" id="sentiero-config">{"eventsUrl": "/sentiero/events"}</script>
<script>
  fetch("/sentiero/assets/manifest.json")
    .then(function (r) { return r.json(); })
    .then(function (m) {
      var s = document.createElement("script");
      s.src = "/sentiero/assets/" + m.recorder;
      s.async = true;
      document.body.appendChild(s);
    })
    .catch(function () {});
</script>
```

Note the config block is mandatory here (the `/assets/` URL breaks the sibling derivation).
