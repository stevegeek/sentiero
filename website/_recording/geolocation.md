---
title: Visitor Geolocation
nav_order: 5
description: Capture visitor country and city into session metadata and analytics — from Cloudflare headers or a custom resolver, without storing IPs.
---

# Visitor Geolocation

Sentiero can enrich each session with the visitor's **country, city, region, and timezone**. Resolution happens server-side at event ingest; the recorder is unchanged and **no IP address is ever stored** — deliberately coarse, in keeping with `anonymize_ip`.

Geo capture is **off by default**. Location headers are ordinary request headers — any client can send them — so only enable a source that your infrastructure actually guarantees.

## Cloudflare

If your app is behind Cloudflare, enable **IP geolocation** (Network settings) for country, and the **"Add visitor location headers" managed transform** (Rules → Transform rules) for city/region/timezone. Then:

```ruby
Sentiero.configure do |config|
  config.geo_source = :cloudflare
end
```

Sentiero reads `CF-IPCountry`, `CF-IPCity`, `CF-Region`, and `CF-Timezone`, skipping Cloudflare's `XX` (unknown) and `T1` (Tor) markers. Country-only capture (no managed transform) is fine — the other fields just stay unset.

> **Caveat:** only set `:cloudflare` when requests genuinely arrive through Cloudflare. If clients can reach your origin directly, they can spoof these headers.

## Any other source

`geo_source` also accepts any callable taking the Rack env and returning a Hash with `"country"`, `"city"`, `"region"`, and/or `"timezone"` string values. This covers other CDNs:

```ruby
# CloudFront (enable the CloudFront-Viewer-Country header policy)
config.geo_source = ->(env) { {"country" => env["HTTP_CLOUDFRONT_VIEWER_COUNTRY"]} }
```

or a self-managed MaxMind database — resolve the IP in-request and return only the coarse result, so the IP itself is never persisted and `anonymize_ip` is unaffected:

```ruby
# Gemfile: gem "maxmind-geoip2"
GEO_DB = MaxMind::GeoIP2::Reader.new(database: "/srv/geoip/GeoLite2-City.mmdb")

config.geo_source = lambda do |env|
  record = GEO_DB.city(env["REMOTE_ADDR"]) # resolve, then discard the IP
  {"country" => record.country.iso_code, "city" => record.city&.name}
rescue MaxMind::GeoIP2::AddressNotFoundError
  nil
end
```

A resolver that raises or returns something other than a Hash is ignored (with a one-time warning) — geo problems never break event ingest.

## Where it shows up

Resolved values are stored as `geo_country`, `geo_city`, `geo_region`, and `geo_timezone` in the session's metadata:

- **Analytics overview** — Countries and Cities cards (shown once geo data exists).
- **Segments** — a Country filter dropdown; filter by city with the generic metadata filter (`metadata_key=geo_city`).
- **Session detail** — in the session's metadata panel.

If a recorded page sets the same key via `setMetadata()`, the page's value wins.
