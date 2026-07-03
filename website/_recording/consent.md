---
title: Implementing Consent & Opt-Out
nav_order: 3
description: Recipes for wiring a consent banner, an opt-out toggle, and a "delete my data" flow around Sentiero.
---

# Implementing Consent & Opt-Out

Sentiero ships the privacy *mechanics* — a consent-gateable script tag, an end-user opt-out API, Global Privacy Control handling, and programmatic erasure — but no consent banner or "delete my data" button. That last mile depends on your app, your CMP, and your jurisdictions. This page is the wiring guide; option reference lives in [Privacy & Masking](/guide/privacy/). None of this is legal advice.

## Which Model Do You Need?

| Model | What it means | When you need it |
|-------|---------------|------------------|
| **Consent-first** | The script tag isn't rendered until the visitor agrees. | EU/UK visitors: `sentiero_sid` / `sentiero_wid` are not strictly-necessary cookies, so ePrivacy/PECR generally require prior consent. |
| **Opt-out** | Recording starts by default; visitors can turn it off, and GPC browsers are never recorded. | CCPA/CPRA-style regimes without a prior-consent rule. |

They compose: a typical EU deployment gates the tag on consent *and* offers an opt-out toggle afterwards.

An opt-out toggle alone is **not** consent-first: the recorder starts on script load, so the initial DOM snapshot is captured before anyone can click "stop". `window.Sentiero.optOut()` is a post-hoc signal. For prior consent, gate the tag.

## Recipe: Consent-First (Gate the Script Tag)

Render the script tag only once a consent cookie your app owns is set:

```erb
<% if request.cookies["analytics_consent"] == "granted" %>
  <%= sentiero_script_tag(events_url: "/sentiero/events") %>
<% end %>
```

A minimal banner sets the cookie and reloads, so the server renders the tag on the next request:

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

The reload is deliberate: script tags injected into a loaded page via `innerHTML` don't run. Injecting `<script>` elements programmatically also works, but the reload variant is harder to get wrong.

**With a CMP**, the shape is identical — in the "analytics accepted" callback, set the cookie your template checks and reload:

```js
function onAnalyticsConsentGranted() {
  document.cookie = "analytics_consent=granted; path=/; max-age=31536000; SameSite=Lax";
  location.reload();
}
```

The [demo app](https://github.com/stevegeek/sentiero/tree/main/demo) implements this recipe end to end.

## Recipe: End-User Opt-Out Toggle

Enable the feature:

```ruby
Sentiero.configure do |config|
  config.user_opt_out = true # activates window.Sentiero.optOut() / optIn()
end
```

then wire a toggle (privacy-settings page, footer) to the browser API:

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

What you get for free (details in [End-user opt-out](/guide/privacy/#end-user-opt-out)):

- `optOut()` acts immediately: stops rrweb, **drops** buffered events unsent, and persists via a cookie plus a `localStorage` flag.
- The server enforces the cookie: a `POST` carrying it stores nothing, even from a stale or tampered client.
- An opt-out → opt-in cycle starts a fresh session; old identifiers are cleared.

One caveat for your UI copy: the server reads only the **cookie**; the client reads cookie *and* `localStorage`. A visitor who clears cookies is still opted out client-side until `optIn()` clears both — steer users to the toggle, not cookie-clearing.

**Global Privacy Control needs no wiring.** `config.respect_gpc` defaults to `true`: GPC browsers are treated as opted out on client and server before any events flow.

## Recipe: "Delete My Data" (Right to Erasure)

Opting out stops *future* recording only. Sentiero deliberately exposes **no public deletion endpoint** — the events endpoint is unauthenticated, and letting any browser delete sessions by client-supplied ID would be an abuse vector. Erasure is an authenticated, server-side action in *your* app (account-deletion hook, DSAR admin screen):

**Step 1 — make sessions findable.** Session IDs are pseudonymous, so tag recordings once the visitor signs in:

```js
window.Sentiero.setMetadata({ userId: "user-42" });
```

**Step 2 — find and erase server-side:**

```ruby
def erase_recordings_for(user_id)
  sessions = Sentiero.store.list_sessions(search: user_id, limit: 1_000)
  Sentiero.erase_sessions(sessions.map { |s| s[:session_id] })
end
```

`erase_sessions` is idempotent and returns the count actually deleted. It does **not** call `audit_log` (only dashboard operations are audited) — log erasures yourself where you call them. `search:` does case-insensitive substring matching over session IDs and metadata values, so use identifiers that can't collide (`"user-42"` also matches `"user-421"` — prefer opaque IDs or a delimited form). Repeat the lookup until it returns nothing if a user may exceed one page.

Two erasure residues to know before you promise deletion: exported replay files live outside the store, and aggregated problem records from error tracking are retained (titles may contain PII). See [Right to erasure](/guide/privacy/#right-to-erasure-gdpr-art-17) for both, plus the `erase_where` time-range variant and `rake sentiero:erase`.

## Retention and Audit

- **Retention** — set `config.retention_period` (seconds) and schedule `Sentiero.purge_expired!` (or `rake sentiero:purge`) so recordings age out. See [Data retention / purge](/guide/privacy/#data-retention--purge).
- **Audit** — set `config.audit_log` to a callable; the dashboard and analytics report sensitive operations (session views, deletions, exports, shares) to it. Programmatic erasure and purge are *not* routed through it — log those at their call sites. See [Audit logging](/guide/privacy/#audit-logging).

## Checklist

| Obligation | What to do |
|------------|------------|
| Prior consent (EU/ePrivacy) | Gate `sentiero_script_tag` on a consent cookie; don't rely on `optOut()` alone |
| Honor opt-out signals | `respect_gpc` is on by default — leave it on |
| Let users change their mind | `user_opt_out = true` + a toggle wired to `optOut()` / `optIn()` |
| Right to erasure | Tag sessions via `setMetadata`, erase with `Sentiero.erase_sessions` on account deletion / DSAR |
| Storage limitation | Set `retention_period` and schedule the purge |
| Accountability | Wire `config.audit_log` for dashboard access; log your own erasure/purge calls; document recording in your privacy notice and ROPA ([data categories](/guide/privacy/#privacy-notice--ropa)) |
| Data minimization | The [masking and redaction defaults](/guide/privacy/) are on — keep them on |
