---
title: Implementing Consent & Opt-Out
nav_order: 3
description: Step-by-step recipes for wiring a consent banner, an opt-out toggle, and a "delete my data" flow around Sentiero.
---

# Implementing Consent & Opt-Out

Sentiero ships the privacy *mechanics* — a consent-gateable script tag, an end-user
opt-out API, Global Privacy Control handling, and programmatic erasure — but it does
not ship a consent banner or a "delete my data" button. Consent UI is inseparable
from your app's design, your consent-management platform, and the jurisdictions you
serve, so the last mile is yours. This page is the wiring guide: copy-paste recipes
for the three flows most deployments need, and a checklist to close out.

Reference detail for every option used here lives in
[Privacy & Masking](/guide/privacy/). None of this is legal advice; which flows you
need depends on your lawful basis and your lawyers.

## Which Model Do You Need?

| Model | What it means | When you need it |
|-------|---------------|------------------|
| **Consent-first** | Recording does not start until the visitor agrees; the script tag is not even rendered before then. | EU/UK visitors. `sentiero_sid` / `sentiero_wid` are not strictly-necessary cookies, so ePrivacy/PECR generally require prior consent. |
| **Opt-out** | Recording starts by default; visitors can turn it off, and browsers signalling GPC are never recorded. | CCPA/CPRA-style regimes and jurisdictions without a prior-consent rule. |

The two compose: a typical EU deployment gates the script tag on consent *and*
offers an opt-out toggle afterwards so a visitor can change their mind.

**Why an opt-out toggle alone is not consent-first:** the recorder starts
synchronously on script load, so by the time a visitor can click "stop recording"
the initial DOM snapshot and early events have already been captured.
`window.Sentiero.optOut()` is a post-hoc signal. For prior consent, gate the tag.

## Recipe: Consent-First (Gate the Script Tag)

Render `sentiero_script_tag` only once the visitor has consented. The consent state
lives in a cookie your app owns:

```erb
<% if request.cookies["analytics_consent"] == "granted" %>
  <%= sentiero_script_tag(events_url: "/sentiero/events") %>
<% end %>
```

A minimal banner sets that cookie and reloads, so the server renders the tag on the
next request:

```html
<div id="consent-banner" hidden>
  <p>We record anonymized sessions to improve this site.</p>
  <button id="consent-accept">Accept</button>
  <button id="consent-decline">Decline</button>
</div>
<script>
  (function () {
    if (document.cookie.includes("analytics_consent=")) return;
    var banner = document.getElementById("consent-banner");
    banner.hidden = false;
    function decide(value) {
      document.cookie = "analytics_consent=" + value +
        "; path=/; max-age=31536000; SameSite=Lax";
      banner.hidden = true;
      if (value === "granted") location.reload();
    }
    document.getElementById("consent-accept")
      .addEventListener("click", function () { decide("granted"); });
    document.getElementById("consent-decline")
      .addEventListener("click", function () { decide("denied"); });
  })();
</script>
```

Reloading after acceptance is deliberate: it is the simplest way to get the freshly
rendered script tag executed (script tags injected into an already-loaded page via
`innerHTML` do not run). If a reload is unacceptable, have your consent callback
create the `<script>` elements programmatically — but the reload variant is harder
to get wrong.

**With a consent-management platform (CMP):** the shape is identical — in the CMP's
"analytics accepted" callback, set the cookie your template checks and reload:

```js
// Called by your CMP when the visitor accepts the analytics category.
function onAnalyticsConsentGranted() {
  document.cookie = "analytics_consent=granted; path=/; max-age=31536000; SameSite=Lax";
  location.reload();
}
```

The [demo app](https://github.com/stevegeek/sentiero/tree/main/demo) implements this
recipe end to end — first visit shows a banner, and the script tag renders only
after acceptance.

## Recipe: End-User Opt-Out Toggle

Once recording is running (whether consent-gated or not), give visitors a switch to
turn it off — typically in a privacy-settings page or footer. Enable the feature:

```ruby
Sentiero.configure do |config|
  config.user_opt_out = true # exposes window.Sentiero.optOut() / optIn()
end
```

then wire a toggle to the browser API:

```html
<button id="recording-toggle"></button>
<script>
  (function () {
    var COOKIE = "sentiero_optout"; // config.opt_out_cookie_name default
    var btn = document.getElementById("recording-toggle");
    function optedOut() {
      return document.cookie.includes(COOKIE + "=1") ||
        localStorage.getItem(COOKIE) === "1";
    }
    function render() {
      btn.textContent = optedOut() ? "Resume session recording"
                                   : "Stop recording my sessions";
    }
    btn.addEventListener("click", function () {
      var api = window.Sentiero || {};
      if (optedOut()) { api.optIn && api.optIn(); } else { api.optOut && api.optOut(); }
      render();
    });
    render();
  })();
</script>
```

What you get for free (details in
[End-user opt-out](/guide/privacy/#end-user-opt-out)):

- `optOut()` acts immediately — it stops rrweb and **drops** any buffered events
  without sending them — and persists across visits via a cookie plus a
  `localStorage` flag.
- The server enforces the cookie too: a `POST` to the events endpoint carrying the
  opt-out cookie stores nothing, even from a stale or tampered client.
- An opt-out → opt-in cycle starts a fresh session; the old identifiers are cleared.

One caveat worth mirroring in your UI copy: the server reads only the **cookie**,
the client reads cookie *and* `localStorage`. A visitor who "clears cookies" is
still opted out until the `localStorage` flag is cleared — `optIn()` clears both,
so steer users to the toggle rather than cookie-clearing.

**Global Privacy Control needs no wiring.** `config.respect_gpc` defaults to `true`:
a browser sending the GPC signal is treated as opted out on both the client and the
server before any events flow.

## Recipe: "Delete My Data" (Right to Erasure)

Opting out stops *future* recording. It does not delete what was already stored, and
Sentiero deliberately exposes **no public deletion endpoint** — the events endpoint
is unauthenticated by design, and letting any browser delete sessions by
client-supplied ID would be an abuse vector. Erasure is therefore a server-side,
authenticated action in *your* app (an account-deletion hook, a DSAR admin screen),
built in two steps.

**Step 1 — make sessions findable.** Session IDs are pseudonymous, so tag each
recording with your user identifier once the visitor is signed in:

```js
window.Sentiero.setMetadata({ userId: "user-42" });
```

**Step 2 — find and erase server-side.** Metadata is searchable through the store,
so the erasure handler is a lookup plus one call:

```ruby
def erase_recordings_for(user_id)
  sessions = Sentiero.store.list_sessions(search: user_id, limit: 1_000)
  Sentiero.erase_sessions(sessions.map { |s| s[:session_id] })
end
```

`erase_sessions` returns the count actually deleted, is idempotent, and is audited
via `config.audit_log` when set. `search:` does case-insensitive substring matching
over session IDs and metadata values, so use identifiers that cannot collide
(`"user-42"` also matches `"user-421"` — prefer opaque IDs or a delimited form like
`"user:42:"`). Repeat the lookup until it returns nothing if a user may have more
sessions than one page.

Know the two erasure residues before you promise deletion: exported replay files
live outside the store, and aggregated problem records from error tracking are
retained (their titles may contain PII). Both are documented under
[Right to erasure](/guide/privacy/#right-to-erasure-gdpr-art-17), along with the
`erase_where` time-range variant and the `rake sentiero:erase` task.

## Retention and Audit

Two more pieces round out the compliance story, both one-liners:

- **Retention** — set `config.retention_period` (seconds) and schedule
  `Sentiero.purge_expired!` (or `rake sentiero:purge`) so recordings age out instead
  of accumulating forever. See [Data retention / purge](/guide/privacy/#data-retention--purge).
- **Audit** — set `config.audit_log` to a callable and Sentiero reports opt-outs,
  erasures, purges, and dashboard operations to it. See
  [Audit logging](/guide/privacy/#audit-logging).

## Checklist

| Obligation | What to do |
|------------|------------|
| Prior consent (EU/ePrivacy) | Gate `sentiero_script_tag` on a consent cookie; don't rely on `optOut()` alone |
| Honor opt-out signals | `respect_gpc` is on by default — leave it on |
| Let users change their mind | `user_opt_out = true` + a toggle wired to `optOut()` / `optIn()` |
| Right to erasure | Tag sessions via `setMetadata`, erase with `Sentiero.erase_sessions` on account deletion / DSAR |
| Storage limitation | Set `retention_period` and schedule the purge |
| Accountability | Wire `config.audit_log`; document recording in your privacy notice and ROPA ([data categories](/guide/privacy/#privacy-notice--ropa)) |
| Data minimization | Review the [masking and redaction defaults](/guide/privacy/) — they're on, keep them on |
