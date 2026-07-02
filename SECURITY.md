# Security Policy

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Please report security issues privately using [GitHub Security Advisories](https://github.com/stevegeek/sentiero/security/advisories/new). This ensures the issue is triaged and a fix is prepared before public disclosure.

When reporting, please include:

- A description of the vulnerability and its potential impact
- Steps to reproduce or a proof-of-concept
- The version(s) of Sentiero affected
- Any suggested fixes, if applicable

You should receive an initial response within 72 hours. We will work with you to understand the issue and coordinate a fix and disclosure timeline.


## Areas Already Reviewed (but possibly still vulnerable!)

The following areas have been through multiple review passes. This does not mean they are free of vulnerabilities,  only that they have been considered. If you find an issue in any of these areas, please still report it.

- **XSS**: HTML escaping (`CGI.escapeHTML`), JS string escaping (including U+2028/U+2029 line terminators), `</script>` injection prevention in JSON config, `textContent` for dynamic DOM content
- **CSRF**: Double-submit cookie with `secure_compare`; token sent via POST body (not query string, avoiding log/history leakage); `HttpOnly; SameSite=Strict` cookie; conditional `Secure` flag over HTTPS
- **CSP**: `Content-Security-Policy`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`
- **Auth resilience**: `auth_callback` exceptions are caught and treated as 403 Forbidden (no 500 leakage)
- **Gzip bomb**: Bounded decompression (`MAX_BODY_SIZE + 1` read limit)
- **Payload size**: 512 KB limit on both raw and decompressed request bodies
- **ID validation**: Alphanumeric + hyphens/underscores only, max 128 chars,  enforced on both EventsApp and DashboardApp routes
- **Timestamp validation**: Rejects `Infinity`, `-Infinity`, `NaN`, and non-numeric timestamp values
- **Resource limits**: Configurable `max_events_per_request`, `max_sessions` (LRU eviction), and `max_events_per_session` (oldest events dropped) to prevent unbounded memory growth
- **Template protection**: ERB templates blocked from static asset serving
- **Directory traversal**: `File.expand_path` + `start_with?` guard on asset serving
- **Thread safety**: Mutex-synchronized store deletions; `Concurrent::Map` for template cache
- **CORS**: Whitelist-based; empty by default (no cross-origin access)

## Scope

The following are in scope for security reports:

- The Sentiero Ruby gem (`lib/sentiero/`)
- The frontend recorder bundle (`frontend/src/`)
- The demo application (`demo/`) where bugs reflect gem-level issues

Out of scope:

- Vulnerabilities in upstream dependencies (rrweb, fflate, etc.),  report those to their respective maintainers
- Issues that require a misconfigured deployment (e.g. running without HTTPS, no auth callback set on the dashboard)
