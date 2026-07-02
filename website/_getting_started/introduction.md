---
title: Introduction
nav_order: 1
description: What Sentiero is and why it exists. Self-hosted session recording and analytics for Ruby.
---

# Introduction

**Sentiero** is in-app browser session recording, replay, and product analytics for Ruby: self-hosted, privacy-first, and framework-agnostic. Drop it into any Rack app (Rails, Sinatra, Roda, Hanami) and understand how people actually use your product, without sending a byte to a third party.

It captures user interactions with [rrweb](https://www.rrweb.io/), stores them server-side through a pluggable storage layer, and replays them from a dashboard that mounts inside your own app.

## See it in action

![Session replay with event timeline and activity sidebar](/assets/screenshots/replay.png)

*The replay view: rrweb playback with a color-coded timeline and activity sidebar.*

![Analytics overview: totals, events-per-day chart, browser and device breakdown, custom-event tags](/assets/screenshots/analytics-overview.png)

*The analytics overview: session totals, an events-per-day chart, and browser/device distributions, all computed on your own server.*

## Why Sentiero

- **Self-hosted and privacy-first.** Session data never leaves your infrastructure. All form inputs are masked before leaving the browser, password masking is enforced in code and cannot be disabled, and anything potentially invasive is opt-in. When you're both controller and processor, compliance gets simpler.
- **Framework-agnostic.** The core `sentiero` gem works with any Rack app. The companion `sentiero-rails` gem adds ActiveRecord storage, a migration generator, and view helpers.
- **Everything included.** No tiers, no feature gates, no usage caps; everything below ships in the MIT-licensed gem.

## What you get

- **Session replay:** full DOM recording with an interactive timeline, activity sidebar, playback speeds, keyboard shortcuts, and multi-window/tab switching.
- **Cross-session analytics:** pages, segments, click heatmaps, scroll depth, Web Vitals, form analytics, and conversion funnels across every recorded session.
- **Client-side error capture:** set `capture_errors: true` to record JavaScript errors and unhandled promise rejections as events in the replay timeline.
- **Server-side error tracking:** `ingest_keys` authenticates server-side exception ingestion; errors are grouped by fingerprint, tracked with occurrence counts and status, and linked to the replay sessions where they happened.
- **Custom events:** an imperative JS API and declarative `data-sentiero-track-*` HTML attributes.
- **Privacy controls:** per-element `data-rr-block` / `data-rr-mask`, user opt-out, and server-side event sanitizers.
- **Pluggable storage:** memory, file, SQLite, Redis, or ActiveRecord, or bring your own backend.
- **Sharing:** deep links with a timestamp, and self-contained HTML replay exports.

## How it compares

**vs raw rrweb.** rrweb is the in-browser record and replay primitive, and nothing more. Sentiero wraps it into a complete, self-hostable product: batching and transport (retry with exponential backoff, plus `sendBeacon` on page unload), server-side storage across five backends, a replay dashboard, cross-session analytics (funnels, frustration signals such as rage and dead clicks, engagement scoring, Web Vitals, scroll depth and heatmaps, conversions), and server-side error tracking with fingerprinting. The biggest difference is the privacy layer rrweb does not provide: enforced password masking, `maskAllInputs` on by default, Global Privacy Control respected by default, user opt-out, server-side sanitizers, IP anonymization, retention and erasure tooling, and an audit log.

**vs Hotjar and SaaS session-recording tools.** Sentiero is self-hosted and embeddable. Your data never leaves your infrastructure, so you are both controller and processor. It mounts as Rack apps inside your own Ruby app, it is open source and free with no per-session or per-seat caps and no sampling quotas, and it is privacy-first by default. The honest tradeoff: you run, secure, and scale it yourself, and the analytics compute on read over a recent window (a configurable session cap, default 5000) rather than querying a pre-aggregated warehouse.

## Status

Sentiero is pre-1.0 and under active development. It is self-hosted only; there is no SaaS offering.

## Next steps

- [Quick Start](/guide/quick-start/): get recording in under a minute.
- [Configuration](/guide/configuration/): every option and its default.
- [Privacy & Masking](/guide/privacy/): the privacy model in detail.
