# Sentiero end-to-end tests (Playwright)

These tests drive the **real** Sentiero demo app (`demo/app.rb`, a Roda app)
in a real Chromium browser. The demo is a small marketing funnel: `/` is a
long, scrollable landing page ("Trailhead"), `/signup` is a signup form, and
the todo list most specs interact with lives at `/app`. The tests exercise
the shipped recorder bundle, the dashboard replay UI, and the
privacy/masking guarantees end to end — complementing the Capybara/Cuprite
Rails system test (`test/rails/system/`), which covers the Rails engine path.

## What it covers

- **`tests/record-replay.spec.ts`** — adds a todo and types into a masked
  input in the demo, navigates to the dashboard (which flushes recorded events
  via `sendBeacon`), waits for the session row to appear, opens it, and
  confirms the replay page loads with the rrweb player container/iframe in the
  DOM.
- **`tests/privacy.spec.ts`** — types a known secret into a masked input and an
  always-masked password field, then fetches the recorded events JSON from the
  dashboard events API and asserts the plaintext never appears (it is stored as
  asterisks).
- **`tests/redaction.spec.ts`** — POSTs a raw, unredacted event batch directly
  to `/sentiero/events` (bypassing the recorder's own client-side redaction
  entirely) and asserts the server-side `Sentiero::Redaction` engine still
  scrubs it before storage — the defense-in-depth guarantee for a buggy or
  non-Sentiero caller.

## How it runs

`playwright.config.ts` starts the demo via `./bin/serve` on
**http://localhost:9393** before the tests, using `webServer.reuseExistingServer`
locally. `bin/serve`:

1. Builds the frontend bundle if `lib/sentiero/web/assets/manifest.json` is
   missing.
2. Runs `bundle install` in `demo/`.
3. Wipes `demo/tmp/sentiero_sessions` so each run starts from an empty,
   deterministic **file store**.
4. Launches puma with `REDIS_URL` unset, so the demo uses the file store (not
   Redis).

Dashboard requests use HTTP Basic auth (`demo` / `demo`), configured via
`httpCredentials` in the Playwright config.

## Running

```bash
cd e2e
npm install
npx playwright install chromium
npm test
```
