---
title: Sharing Replays
nav_order: 3
description: Shareable deep links and self-contained HTML replay exports.
---

# Sharing Replays

Two optional features let a recorded session leave the dashboard: a **self-contained HTML export** of a single session, and a **play-from-JSON import** page that replays an exported session in the browser. Both live under the analytics mount.

## The `shareable_replays` gate

Both features are gated by `config.shareable_replays`, which **defaults to `false`**.

```ruby
Sentiero.configure do |config|
  config.shareable_replays = true # opt in deliberately
end
```

When off (the default):

- `GET /analytics/share/:id` returns `404` as if the route did not exist.
- `GET /analytics/import` returns `404`.
- No share/import UI links render (the export index is told the feature is off).

The demo app enables it so the feature can be exercised end to end; production deployments should leave it off unless sharing is actually needed.

## HTML export: `/analytics/share/:id`

`ShareableReplay` builds a single, self-contained HTML document for a whole session. The vendored rrweb-player JS and CSS (the same files the dashboard serves) and the session's events (merged across all windows and sorted into one time-ordered stream) are all inlined, so the file replays offline with no server.

The route validates the session ID format, returns `404` for an unknown session or one with nothing to replay, and serves the document as an attachment (`session-<id>.html`). The download is audited (`share`) when `config.audit_log` is set.

### Security

- **A share file is a full session dump.** It contains everything recorded for that session (DOM snapshots, interactions, metadata), which **may contain PII**, and it leaves your infrastructure as a standalone file. Enable `shareable_replays` deliberately and treat exported files as sensitive. Server-side masking/sanitization (see [Privacy & Masking](/guide/privacy/)) still applies to what was recorded, but anything captured is in the file.
- **No `</script>` breakout.** The inlined events are emitted inside a `<script type="application/json">` block and escaped so that a `</script>` (or `<`, `>`, `&`, JS line separators) appearing in the event data cannot break out of the script context. The bootloader reads that block's text and `JSON.parse`s it.

## Import (play from JSON): `/analytics/import`

The import page replays a previously exported session **entirely in the browser**. The page bundle reads the pasted or dropped JSON, parses it, and feeds it to rrweb-player; the server handler only renders the page (no upload is stored).

### Security

Imported input is treated as **untrusted**. It is handled with `JSON.parse` only, never `eval`, so a malicious file cannot execute arbitrary code through the parser. Because replay reconstructs a DOM, only import files from sources you trust.
