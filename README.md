<p align="center">
  <img src="logo.svg" alt="Sentiero" width="80" />
</p>

<h1 align="center">Sentiero</h1>

<p align="center">
  <strong>In-app browser session recording and replay for Ruby.</strong><br>
  Self-hosted. Privacy-first. Framework-agnostic.
</p>

---

Sentiero is an open-source Ruby gem for embedding session recording and replay directly in your application — similar to Hotjar, Microsoft Clarity, or PostHog's session replay, but self-hosted and under your control.

It captures user sessions via [rrweb](https://www.rrweb.io/), stores them server-side with pluggable backends, and provides a built-in replay dashboard. No data leaves your infrastructure. No third-party tracking scripts. Session data stays in your environment, which for many teams feels meaningfully different from forwarding user behaviour to an external SaaS.

Sentiero is framework-agnostic: the core gem works with any Rack-compatible framework (Roda, Sinatra, Hanami, etc.), and a separate `sentiero-rails` gem provides deeper Rails integration with ActiveRecord storage, a migration generator, and view helpers. It was built as an alternative to gems like [SpectatorSport](https://github.com/bensheldon/spectator_sport) for teams that want session recording without being tied to Rails.

### Why Sentiero?

- **De-SaaS your session recording** — keep user interaction data in your own infrastructure instead of sending it to third-party services
- **Privacy-respecting defaults** — all inputs masked by default, password masking enforced and cannot be disabled, per-element control via HTML attributes
- **User-side controls** — respects Do Not Track (DNT) and Global Privacy Control (GPC), with support for explicit user opt-in/opt-out
- **Framework-agnostic** — drop into any Rack-compatible app, or use the dedicated Rails integration
- **Complete but focused** — session recording, replay, and the tools around them, without trying to be an analytics platform

### Status

Sentiero is under active development. The core session recording and replay functionality is working and approaching an initial release.

A paid "Pro" companion gem is planned that will extend the open-source edition with aggregated insights across sessions (heatmaps, analytics). The core gem will always remain open source.

### License

[MIT](LICENSE.txt)
