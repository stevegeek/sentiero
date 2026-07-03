---
title: Production Considerations
nav_order: 3
description: What to review before deploying Sentiero to a production environment.
---

# Production Considerations

A pre-deployment checklist. Each row links to the page that owns the detail.

## Checklist

| Concern | Action |
|---------|--------|
| **HTTPS** | Serve over HTTPS. The CSRF cookie requires `Secure`; recordings contain user behavior data. |
| **Dashboard auth** | Set `basic_auth` or `auth_callback`. See [Authentication](/guide/authentication/). |
| **Store** | Pick a backend for your traffic and topology. See [Storage](/guide/storage/). |
| **Resource limits** | Set `max_sessions` and `max_events_per_session` to cap memory/storage growth. See [Configuration](/guide/configuration/). |
| **Retention** | Set `retention_period` and schedule purges. See [Privacy](/guide/privacy/). |
| **CORS** | Set `cors_origins` to your frontend's actual origin(s). See [CORS](#cors-hardening) below. |
| **Encryption at rest** | Stored events are unencrypted. See [Encryption at Rest](#encryption-at-rest) below. |
| **IP anonymization** | On by default (`anonymize_ip: true`); only disable it if you have a specific reason to keep raw IPs. See [Privacy](/guide/privacy/). |
| **Visitor geolocation** | Optional. Behind Cloudflare or other CDNs, set `config.geo_source` to add country/city to analytics with no IP storage. See [Visitor Geolocation](/guide/geolocation/). |
| **Rate limiting** | Add `Rack::Attack` or nginx `limit_req` on the events endpoint. Sentiero enforces payload size limits, not rate limits. |

## Authentication

The dashboard is open to anyone by default on non-Rails frameworks; never deploy without setting `basic_auth` or `auth_callback`. Both fail closed. See [Authentication](/guide/authentication/) for the full guide.

## Store

Choose a backend appropriate for your traffic volume and process topology. See [Storage](/guide/storage/) for the backend comparison and configuration examples.

## Data Retention

Set `retention_period` and run `Sentiero.purge_expired!` (or `rake sentiero:purge` in Rails) from a scheduler. See [Privacy](/guide/privacy/) for retention and right-to-erasure, and [Configuration](/guide/configuration/) for the option itself.

## Privacy Options and Redaction

Side-channel redaction (`config.redaction`), IP anonymization, GPC, and opt-out are all configured for production the same way as anywhere else. See [Privacy](/guide/privacy/).

## Encryption at Rest

Event payloads are stored **unencrypted** in every built-in store (Memory, File, SQLite, Redis, ActiveRecord). DOM snapshots can contain personal data even with masking enabled, so protecting recordings at rest is the operator's responsibility: enable database-level or disk-level encryption (encrypted volumes, transparent database encryption, an encrypted Redis deployment) on whatever backend you run.

## Server-Side Error Ingestion

If you accept errors from other processes via the server-side reporter, configure `ingest_keys`. See [Error Tracking](/guide/error-tracking/).

## CORS Hardening

`cors_origins` must list the exact origin(s) that serve your frontend; the empty default blocks all cross-origin event submissions and wildcards are not supported.

```ruby
Sentiero.configure do |config|
  config.cors_origins = ["https://app.example.com", "https://www.example.com"]
end
```

CORS only stops browser-initiated cross-origin requests. It does not prevent a server-side POST to the events endpoint, so use `ingest_keys` to authenticate non-browser ingest (see [Error Tracking](/guide/error-tracking/)).
