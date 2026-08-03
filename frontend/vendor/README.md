# Vendored assets

- `rrweb-player.js` — `rrweb-player@2.1.1` `dist/rrweb-player.umd.min.cjs` from
  https://unpkg.com/rrweb-player@2.1.1/dist/rrweb-player.umd.min.cjs
- `rrweb-player.css` — `rrweb-player@2.1.1` `dist/style.min.css`

When upgrading, avoid 2.0.0–2.1.0: those production builds shipped with Svelte
lifecycle APIs stubbed out (fixed in 2.1.1). Keep the version in step with the
`@rrweb/record` dependency in `package.json`.
