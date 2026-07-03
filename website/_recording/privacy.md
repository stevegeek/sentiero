---
title: Privacy & Masking
nav_order: 2
description: Privacy-first defaults, input masking, and per-element recording controls.
---

# Privacy & Masking

## Default Behavior

Sentiero masks all form input values by default. Values typed into text fields, textareas, selects, and other inputs are replaced with asterisks in the recording. No raw input data reaches the server.

Password masking is **enforced on both the Ruby backend and the JavaScript frontend** and cannot be disabled. Even if you set `mask_all_inputs = false`, password fields remain masked. See [`mask_input_options`](#mask_input_options) for details.

Text content inside elements matched by `mask_text_selector` is also masked (non-whitespace characters replaced with `*`).

## Per-Element Control

Three rrweb HTML attributes control recording behavior on individual elements:

| Attribute | Effect |
|-----------|--------|
| `data-rr-block` | Element is excluded from recording entirely. Replaced with a placeholder in replay. |
| `data-rr-mask` | Text content within the element is masked (non-whitespace replaced with `*`). |
| `data-rr-ignore` | DOM mutations within the element are not recorded. Initial state is captured but changes are dropped. |

These apply to the element and its descendants. Use `data-rr-block` for sections containing PII or sensitive content (account numbers, one-time tokens, user-generated content). Use `data-rr-ignore` for high-frequency DOM updates that add noise without value (live tickers, animations).

### Input masking is not enough for server-rendered PII

`mask_all_inputs` masks values the user **types**. PII the **server renders into the page** is captured as ordinary DOM text and is *not* masked by that setting:

```erb
<!-- WRONG: "Welcome, Ada Lovelace!" is recorded verbatim -->
<h1>Welcome, <%= current_user.name %>!</h1>

<!-- RIGHT: mask the rendered text -->
<h1 data-rr-mask>Welcome, <%= current_user.name %>!</h1>
```

Audit anywhere the server prints user data (greetings, order summaries, invoices, profile pages) and apply `data-rr-mask` (mask text) or `data-rr-block` (drop the element). When you can pattern-match the text but can't annotate it (third-party widgets, generated markup), use the [DOM text redaction backstop](#side-channel-redaction) (`dom_patterns` / `custom_patterns`) as an opt-in server-side pass.

## Selective Unmasking

When `mask_all_inputs` is `true` (the default), `data-sentiero-unmask` selectively reveals specific inputs or sections:

```html
<input type="text" name="search" data-sentiero-unmask>

<div data-sentiero-unmask>
  <input type="text" name="city">
  <span>This text is also unmasked</span>
</div>
```

This works via custom `maskInputFn` and `maskTextFn` callbacks that check `element.closest("[data-sentiero-unmask]")`. If the element or any ancestor has the attribute, the original value is returned instead of the masked version.

Password inputs are always masked. Sentiero's `maskInputFn` masks every password input first, then delegates non-password inputs to any custom `maskInputFn` you supply, and only falls back to the unmask check otherwise. So a password value can never be revealed by `data-sentiero-unmask` or by a custom `maskInputFn`.

> **Warning:** `data-sentiero-unmask` is matched with `closest()`, so placing it on a container unmasks all descendant inputs and text in that subtree, not just one field. Password inputs stay masked regardless.

Providing your own `maskInputFn` via `recorder_options` replaces Sentiero's per-element unmask logic for non-password inputs; you must reimplement that unmask behavior yourself. Password masking still runs first and cannot be bypassed. A custom `maskTextFn` likewise replaces the text unmask logic entirely.

## Global Recording Options

Configure these in your `Sentiero.configure` block. They map to rrweb recorder options (converted from snake_case to camelCase automatically):

| Config attribute | Default | Description |
|---------|---------|-------------|
| `mask_all_inputs` | `true` | Mask all form input values |
| `mask_input_options` | `{}` | Per-input-type masking hash. See [`mask_input_options`](#mask_input_options) below. |
| `block_selector` | `"[data-rr-block]"` | CSS selector for elements excluded from recording |
| `mask_text_selector` | `"[data-rr-mask]"` | CSS selector for elements with masked text content |
| `ignore_selector` | `"[data-rr-ignore]"` | CSS selector for elements whose mutations are ignored |
| `sampling` | `{ scroll: 150, input: "last" }` | Throttling for scroll (ms interval) and input events |

You can extend selectors to match your own classes:

```ruby
config.block_selector = "[data-rr-block], .sensitive-content"
```

The `recorder_options` escape hatch forwards arbitrary camelCase keys to rrweb. First-class attributes above take precedence when keys overlap.

### `mask_input_options`

This hash controls masking per input type. Keys are input types (`:password`, `:email`, `:tel`, etc.), values are booleans. Example:

```ruby
config.mask_input_options = { email: true, tel: true }
```

This gets merged with the enforced `{ password: true }`. You can add types but you cannot set `password: false`; it will be overwritten. Enforcement is hardcoded in two places: `Configuration::ENFORCED_PRIVACY` on the Ruby side, and `mergePrivacyDefaults()` in `privacy.js` on the JavaScript side. The frontend masking callback also masks password inputs unconditionally, so `data-sentiero-unmask` never exposes a password value.

When `mask_all_inputs` is `true`, this option has no visible effect since everything is already masked. It becomes relevant if you set `mask_all_inputs = false` and want to selectively mask specific input types.

## Browser Storage & Cookies

Sentiero writes to both browser storage and first-party cookies once recording starts.

**Storage (session/window IDs):**

- **Session ID**: stored in `localStorage` when `cross_tab_sessions: true` (the default), so all tabs share one session ID and a user's activity is linked across tabs. Set `cross_tab_sessions = false` to use `sessionStorage` instead, giving each tab an independent session with no cross-tab correlation.
- **Window ID**: always stored in `sessionStorage`, regardless of the `cross_tab_sessions` setting.

`localStorage` persists until explicitly cleared (session IDs can span browser restarts); `sessionStorage` is scoped to the tab lifetime (closing the tab destroys the session ID). If storage access fails (private browsing, storage full), both modes fall back to an in-memory ID for the current page load only.

**First-party cookies:**

On every recording start, two first-party cookies are set:

| Cookie | Purpose |
|--------|---------|
| `sentiero_sid` | Mirrors the session ID |
| `sentiero_wid` | Mirrors the window ID |

Both cookies are set with `max-age` of 1 year, `SameSite=Lax`, and the `Secure` flag when the page is served over HTTPS. They exist so the server-side reporter middleware (`Sentiero::Reporter`) can read them and link server exceptions to the corresponding front-end replay. The server cannot read `localStorage` or `sessionStorage`.

**These cookies are set only after the `shouldRecord()` gate passes.** Users who have opted out or whose browser signals Global Privacy Control never receive `sentiero_sid` or `sentiero_wid`.

**Cookie-banner implication (EU/ePrivacy/PECR):** `sentiero_sid` and `sentiero_wid` are not strictly necessary for the website's technical operation; they exist for analytics/replay linking. Under ePrivacy Directive / PECR, non-strictly-necessary first-party cookies generally require prior consent in the EU. **EU deployments using the default configuration likely need a consent banner**, or must gate `sentiero_script_tag` rendering on consent (see [Deferring recording until consent](#deferring-recording-until-consent)).

## Deferring Recording Until Consent

Recording begins **immediately on script load**: `init()` runs synchronously when the script executes. There is no built-in lazy-start or consent-first API.

For consent-first flows (required in the EU under ePrivacy/GDPR), the operator must gate injection of the script tag itself on consent. Do **not** inject `sentiero_script_tag` until the user has accepted:

```erb
<% if session[:recording_consent_given] %>
  <%= Sentiero::Web::ScriptTag.render %>
<% end %>
```

Or, with a JavaScript consent manager that fires a callback:

```js
// Called by your consent banner when the user accepts analytics cookies.
function onConsentAccepted() {
  // Dynamically inject the script tag.
  const script = document.createElement("script");
  script.src = "/sentiero/assets/recorder.js";
  document.head.appendChild(script);
}
```

**Opt-out is not a substitute for consent gating.** `window.Sentiero.optOut()` is a post-hoc signal: the recorder has already started before the user can call it, which means the initial DOM snapshot and any early events have already been captured. For consent-first compliance, gate the tag at render time.

A complete banner-plus-gating recipe, including the CMP-callback variant, is in [Implementing Consent & Opt-Out](/guide/consent/).

## Right to Erasure (GDPR Art. 17)

When a data subject exercises their right to erasure, you can delete their recordings programmatically, beyond the per-session delete button in the dashboard.

Every recording is keyed by session ID, so erasure works at the session level. Map a user to their session IDs using whatever metadata you record (for example via `window.Sentiero.setMetadata({ userId: "..." })` or your own correlation mechanism), then erase those sessions. A step-by-step "delete my data" recipe is in [Implementing Consent & Opt-Out](/guide/consent/#recipe-delete-my-data-right-to-erasure).

```ruby
# Erase specific sessions (returns the number actually deleted).
Sentiero.erase_sessions(["sess-abc", "sess-def"])

# Erase every session whose last activity falls in a time range
# (inclusive bounds; at least one bound is required).
Sentiero.erase_where(since: Time.parse("2026-01-01"), until_time: Time.parse("2026-02-01"))
Sentiero.erase_where(until_time: 30.days.ago) # everything older than 30 days
```

Both helpers are store-agnostic and work with every backend (Memory, File, SQLite, Redis, Rails AR).

Rails apps can run the same operations from a rake task:

```bash
rake sentiero:erase SESSION_ID=sess-abc
rake sentiero:erase SESSION_IDS=sess-abc,sess-def
rake sentiero:erase SINCE=2026-01-01 UNTIL=2026-02-01
```

Notes:

- **Irreversible.** Erasure deletes the session, its windows, and all recorded events. There is no recovery.
- **Idempotent.** Erasing an unknown or already-deleted session is a no-op and is not counted as deleted.
- **Time range uses last activity** (`updated_at`) and is inclusive on both ends.
- **Bulk scans are capped** at `analytics_max_scan_sessions` (default 5000). Call `erase_where` repeatedly to erase larger backlogs.
- **Sentiero store only.** Erasure removes data from the configured store. It does not touch copies you may have forwarded elsewhere (logs, your own `audit_log` records, external integrations).
- **Exports are a separate egress path.** Shareable replay exports produce standalone HTML files outside the store; erasure does not reach already-exported files. See [Sharing Replays](/guide/sharing/).
- **Aggregated problem records are retained.** For deployments using error tracking, erasing a session deletes its events, metadata, and error occurrences, but the aggregated Problem record is intentionally kept. Its title and message are derived from the exception message and may still contain PII. This is a known erasure residue alongside the exported-HTML gap above.

## Known Limitations

**Initial snapshot masking:** Some rrweb versions don't consistently call `maskInputFn` during the initial full DOM snapshot. Pre-filled input values present on page load may appear masked in the snapshot even when marked with `data-sentiero-unmask`. Values captured from subsequent input events work correctly. This is an upstream rrweb issue, not something Sentiero can fix.

**`maskTextFn` scope:** The `maskTextFn` callback replaces non-whitespace characters with `*`. It applies to text nodes inside elements matched by `mask_text_selector` and, when `data-sentiero-unmask` is used, to all text nodes (to determine whether to unmask). This means text masking only masks visible characters -- whitespace and layout are preserved in the recording.

**Inline styles and CSS:** rrweb captures computed styles. CSS class names, inline styles, and layout information are always recorded. If class names or data attributes contain sensitive information, `data-rr-block` the containing element.

## PII in URLs

When capture features are enabled (`capture_metadata`, `track_navigation`, `track_forms`), Sentiero captures URL strings from the page. The redaction engine strips the query string and fragment by default (`url_mode: :strip`), so query-borne PII does not reach the store even when masking is on. See [Side-channel redaction](#side-channel-redaction) to configure URL handling, including the `url_param_allowlist` and `:keep_filtered` mode.

## Compliance features

These options support GDPR/CCPA-style obligations. All are off (or no-op) by default and opt in through `Sentiero.configure`.

### End-user opt-out

Let a visitor turn recording off for themselves (a ready-made toggle recipe is in [Implementing Consent & Opt-Out](/guide/consent/#recipe-end-user-opt-out-toggle)). Enable the feature and, optionally, name the cookie:

```ruby
Sentiero.configure do |config|
  config.user_opt_out = true               # default: false
  config.opt_out_cookie_name = "sentiero_optout" # this is the default
end
```

The visitor toggles it from the browser:

```js
window.Sentiero.optOut() // sets opt-out cookie AND localStorage key; stops any live session now
window.Sentiero.optIn()  // clears both
```

`optOut()` takes effect immediately, not just on the next page load. In addition to setting the opt-out cookie and `localStorage` flag for future loads, it stops the in-progress recording on the spot: it stops rrweb, stops the transport, and drops the buffered events without sending them, so nothing captured before opt-out leaves the browser. (The initial snapshot and any events already flushed to the server before the call are not retroactively removed.)

**Note on storage asymmetry:** `optOut()` writes both the opt-out cookie and a `localStorage` entry (same name as the cookie). The server enforces opt-out by reading the **cookie only**; it does not read `localStorage`. The `localStorage` key is there because the client-side check runs before cookies are sent on the events request, so both signals are checked on the client. If a user clears cookies expecting to undo an opt-out, they must also clear the `localStorage` key (under the same cookie name); otherwise the client-side check will still prevent recording even though the server-side check would have passed.

When the cookie is present the recorder skips initialization client-side. As defense in depth, `EventsApp` also drops batches server-side: a `POST` carrying the opt-out cookie is answered `204` and **nothing is stored**, even if the client-side check was bypassed.

### Global Privacy Control (GPC)

```ruby
config.respect_gpc = true # default: true
```

When on, a browser signalling Global Privacy Control is treated as opted out, so recording does not start. This is the default, so honoring GPC is the out-of-the-box behavior.

### Side-channel redaction

Input masking covers the DOM recording channel. The opt-in capture features write to separate channels that masking does not reach:

| Feature | Channel data |
|---------|-------------|
| `track_navigation` | Link URL, link text |
| `track_forms` | Form name/id, page URL |
| `capture_metadata` | Page URL, referrer, entry URLs |
| `capture_errors` | Error message and stack trace |
| `capture_clicks` | CSS selector |

The redaction engine (`Sentiero::Redaction` on the server, `redaction.js` in the browser) applies automatically when a feature is enabled. Data is redacted client-side first; the server re-applies as defense-in-depth.

Configure in your `Sentiero.configure` block:

```ruby
config.redaction.url_mode            = :strip               # default: keep path, drop query+fragment
config.redaction.url_param_allowlist = %w[utm_source gclid] # keep these verbatim in :keep_filtered mode
config.redaction.url_param_denylist  = %w[order_ref]        # drop these (augments built-in list)
config.redaction.disabled_patterns   = %i[long_hex]         # relax a built-in free-text pattern
config.redaction.custom_patterns     = [/\bACCT-\d{6}\b/]   # add your own patterns
config.redaction.dom_patterns        = %i[email]            # opt-in: apply built-in patterns to DOM text
config.redaction.server_proc         = ->(event) { ... }    # Ruby-only backstop, runs after the engine
```

**URL mode.** `:strip` (default) keeps scheme, host, and path; drops query string and fragment. `:keep_filtered` retains query params, dropping any in the built-in sensitive-name list (`token`, `api_key`, `session`, `otp`, and others) or in `url_param_denylist`; params in `url_param_allowlist` are kept verbatim; remaining values run through text redaction. `:keep_all` passes the URL verbatim.

**Free-text patterns.** Error messages, stack traces, navigation link text, and click selectors run through five named patterns by default, each replacing matches with `[redacted]`:

| Pattern | Matches |
|---------|---------|
| `email` | Email addresses |
| `url` | URL substrings (query/fragment stripped) |
| `jwt` | `eyJ`-style three-segment tokens |
| `long_hex` | Hex runs >= 32 characters (API keys, hashes) |
| `card` | Card-like 13-19 digit runs |

Disable any with `disabled_patterns: %i[long_hex]`; add app-specific patterns via `custom_patterns`.

**DOM text.** The pattern set is off for rrweb DOM events by default. Opt-in via `dom_patterns` (select built-in patterns to apply) or `custom_patterns` (always applied to DOM text). This is the ingest-side backstop for server-rendered PII you cannot annotate with `data-rr-mask`.

**Not auto-redacted.** Events from `window.Sentiero.addCustomEvent`, `data-sentiero-track-*` attributes, and `__perf` performance events are not processed by the declarative engine. Use `server_proc` to scrub them.

**`server_proc`.** A Ruby-only hook that runs on ingest after the declarative engine, for logic that cannot or should not run in the browser. Fail-closed: a raising proc drops the event rather than storing it unsanitized.

### IP anonymization

> **GDPR note:** IP addresses are personal data under GDPR (they can identify a natural person, directly or in combination). Anonymization is on by default; set `anonymize_ip: false` only if you have a specific reason to keep raw IPs.

```ruby
config.anonymize_ip = false # default: true
```

When on, client IPs are truncated before they reach a store or log via `Sentiero::IpAnonymizer`: the last IPv4 octet is zeroed (`/24`) and the last IPv6 bits masked (`/48`). This also applies to the IP recorded in the audit log. Anonymization is one-way and best-effort, not a re-identification guarantee.

```ruby
Sentiero::IpAnonymizer.anonymize("203.0.113.42") # => "203.0.113.0"
```

### Data retention / purge

Drop sessions past a retention window. `retention_period` is an integer number of seconds (default `nil` = keep forever):

> **GDPR note:** The default `nil` means recordings are kept indefinitely. Under GDPR Art. 5(1)(e) (storage limitation), personal data should not be kept longer than necessary. Set `retention_period` and schedule `Sentiero.purge_expired!` (or the rake task) to run regularly.

```ruby
config.retention_period = 30 * 24 * 60 * 60 # 30 days
```

`Sentiero.purge_expired!` deletes everything older than the window and returns the count (a no-op returning `nil` when `retention_period` is unset). It calls `Store#purge_older_than(seconds)`, which every backend implements. Run it from a scheduler (non-Rails) or the rake task (Rails):

```ruby
Sentiero.purge_expired!
```

```bash
rake sentiero:purge
```

Purge is destructive and irreversible.

### Audit logging

Record who did what to recorded data. `audit_log` is any callable; it receives the action, session ID, acting user, IP, and a timestamp:

```ruby
config.audit_log = lambda do |entry|
  Rails.logger.info("[sentiero audit] #{entry.inspect}")
end
```

The dashboard and analytics call it for sensitive operations (session deletion, segment listing, export, share). The logged IP is anonymized when `anonymize_ip` is on. Audit logging never breaks the request. If your callable raises, the operation still completes.

## Privacy Notice & ROPA

If you operate Sentiero for EU users, you are a data controller and should document session recording in your privacy notice and Records of Processing Activities (ROPA). Data categories to include:

- **Session identifiers** (`sentiero_sid`, `sentiero_wid`): pseudonymous; not directly identifying on their own.
- **IP address**: personal data under GDPR; truncated by default (`anonymize_ip: true`).
- **User agent string**: personal data (can narrow down to an individual in combination with IP/session).
- **Page URLs**: may carry PII in query strings; the default `url_mode: :strip` removes query strings and fragments. See [Side-channel redaction](#side-channel-redaction).
- **DOM interactions**: keyboard input is masked by default; use `data-rr-block` / `data-rr-mask` for sensitive page regions.

Sentiero does not claim GDPR compliance on your behalf. Compliance depends on your configuration choices, the lawful basis you rely on, and how you operate the tool.
