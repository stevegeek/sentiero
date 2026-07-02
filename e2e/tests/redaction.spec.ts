import { test, expect } from "./fixtures";

/**
 * Server-side redaction end-to-end test (formerly sanitize-events.spec.ts).
 *
 * `config.sanitize_events` / `Sentiero::Sanitizers` were removed from the gem;
 * server-side scrubbing now runs through the built-in redaction engine
 * (`Sentiero::Redaction`) automatically on every ingest, with no demo
 * configuration required (see the comment in demo/app.rb). Its defaults are:
 *   - url_mode :strip drops query strings from URLs.
 *   - the builtin email pattern replaces email-looking text with "[redacted]".
 *
 * Proving this end to end via the browser is no longer possible the way the
 * old test did: recorder.js/transport.js now run the SAME redaction engine
 * client-side on every event before it is ever sent (redactEvent in
 * transport.js, redactPayload for window.Sentiero.addCustomEvent), so a
 * normal page session is already redacted before it leaves the browser and
 * can't demonstrate the server doing independent work.
 *
 * The genuine server-side-only scenario is the one EventsApp's own comment
 * describes: "a buggy or non-Sentiero caller" posting raw, unredacted events
 * directly to the public /sentiero/events endpoint, bypassing the recorder's
 * JS (and its client-side redaction) entirely. We do exactly that with the
 * `request` fixture (a plain HTTP client, not a page), then read the STORED
 * events back through the authenticated dashboard events API and assert the
 * PII never survived — proving the server re-redacts independently.
 */

const DASHBOARD = "/sentiero/dashboard/";
const EMAIL = "leak@example.com";
const TRACKING_URL = "http://localhost:9393/app?utm_source=leaktest&session=abc123";

test("server-side redaction scrubs a raw, non-Sentiero POST to the events endpoint", async ({
  request,
}) => {
  const sessionId = `e2e-redaction-${Date.now()}`;
  const windowId = "w1";

  // A hand-built batch a buggy or malicious client could send directly,
  // entirely bypassing recorder.js's client-side redaction:
  //   - a rrweb Meta event (type 4) whose href carries tracking params, and
  //   - a custom event (type 5) with an application-defined tag ("profile",
  //     not one of Sentiero's own side-channel tags) whose payload carries a
  //     raw email address.
  const events = [
    {
      type: 4,
      data: { href: TRACKING_URL },
      timestamp: Date.now(),
    },
    {
      type: 5,
      data: { tag: "profile", payload: { contact: EMAIL } },
      timestamp: Date.now(),
    },
  ];

  const postResponse = await request.post("/sentiero/events", {
    headers: { "content-type": "application/json" },
    data: JSON.stringify({ sessionId, windowId, events }),
  });
  expect(postResponse.ok(), `POST /sentiero/events -> ${postResponse.status()}`).toBeTruthy();

  // Read the STORED events back through the dashboard events API (basic auth
  // applied globally via httpCredentials).
  const eventsResponse = await request.get(
    `${DASHBOARD}api/sessions/${sessionId}/windows/${windowId}/events`,
  );
  expect(
    eventsResponse.ok(),
    `events API -> ${eventsResponse.status()}`,
  ).toBeTruthy();
  const stored = await eventsResponse.json();
  expect(Array.isArray(stored)).toBeTruthy();
  expect(stored.length).toBe(2);

  const raw = JSON.stringify(stored);

  // Neither the raw email nor the tracking query string ever reached storage.
  expect(raw).not.toContain(EMAIL);
  expect(raw).not.toContain("utm_source=leaktest");
  expect(raw).not.toContain("session=abc123");

  // Be specific: the meta event's href kept its base URL but lost the query
  // string (default url_mode :strip)...
  const meta = stored.find((e: any) => e?.type === 4);
  expect(meta, "stored meta event present").toBeTruthy();
  expect(meta.data.href).toBe("http://localhost:9393/app");

  // ...and the unmapped custom event's payload field was redacted in place
  // (deep-redacted, since "profile" isn't one of Sentiero's own side-channel
  // tags) rather than dropped or passed through raw.
  const profile = stored.find((e: any) => e?.type === 5 && e?.data?.tag === "profile");
  expect(profile, "stored profile custom event present").toBeTruthy();
  expect(profile.data.payload.contact).toBe("[redacted]");
});
