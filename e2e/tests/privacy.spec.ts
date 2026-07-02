import { test, expect, Page, flushRecorder, gotoApp } from "./fixtures";

/**
 * Privacy end-to-end test: type a known secret into a masked input, flush the
 * session, then assert the plaintext secret never appears in the recorded
 * events. Mirrors the intent of the Rails system test's masking assertions
 * (test/rails/system/session_recording_test.rb), but against the demo app.
 *
 * Asserting on raw events through the browser DOM is awkward, so we fetch the
 * events JSON directly from the dashboard events API (HTTP Basic auth is
 * configured globally) and assert on the JSON.
 */

const DASHBOARD = "/sentiero/dashboard/";
const SECRET = "SuperSecret123";

async function findEventsUrl(page: Page): Promise<string> {
  // Poll the dashboard until a session row appears, then open it and read the
  // player config which contains the events API URL for the window.
  const sessionLink = page.locator("a.session-id").first();
  await expect(async () => {
    await page.goto(DASHBOARD, { waitUntil: "domcontentloaded" });
    await expect(sessionLink).toBeVisible({ timeout: 2000 });
  }).toPass({ timeout: 30_000, intervals: [1000, 1000, 2000] });

  await sessionLink.click();
  await expect(page.locator("#replayer")).toBeAttached();

  const configJson = await page
    .locator("#sentiero-player-config")
    .textContent();
  expect(configJson, "player config JSON present").toBeTruthy();
  const config = JSON.parse(configJson as string);
  expect(config.eventsUrl, "eventsUrl present in player config").toBeTruthy();
  return config.eventsUrl as string;
}

test("masked input is not stored in plaintext", async ({ page }) => {
  await gotoApp(page);

  // Type the secret into the masked text input.
  const maskedInput = page.locator(
    'input[placeholder="Type something here (will be masked in replay)"]',
  );
  await maskedInput.fill(SECRET);

  // Also exercise the always-masked password input.
  const passwordInput = page.locator(
    'input[placeholder="Password (always masked, enforced)"]',
  );
  await passwordInput.fill("HiddenPass");

  // Flush buffered events (tab-hide -> sendBeacon), confirmed by the POST.
  await flushRecorder(page);

  // Resolve the events API URL for the recorded session/window.
  const eventsUrl = await findEventsUrl(page);

  // Fetch the raw events JSON (basic auth applied from config).
  const resp = await page.request.get(eventsUrl);
  expect(resp.ok(), `events API ${eventsUrl} -> ${resp.status()}`).toBeTruthy();
  const events = await resp.json();
  expect(Array.isArray(events)).toBeTruthy();
  expect(events.length).toBeGreaterThan(0);

  const raw = JSON.stringify(events);

  // The plaintext secret must NOT appear anywhere in the recorded events.
  expect(raw).not.toContain(SECRET);
  expect(raw).not.toContain("HiddenPass");

  // Sanity: masking replaces characters with asterisks, so the recorded input
  // text should contain a run of asterisks matching the secret length.
  const inputEvents = (events as any[]).filter(
    (e) => e.type === 3 && e?.data?.source === 5,
  );
  const inputTexts = inputEvents
    .map((e) => e?.data?.text)
    .filter((t) => typeof t === "string");
  expect(
    inputTexts.some((t) => t === "*".repeat(SECRET.length)),
    `expected masked asterisks of length ${SECRET.length}; got ${JSON.stringify(
      inputTexts,
    )}`,
  ).toBeTruthy();
});

/**
 * Global Privacy Control: with respect_gpc enabled (the demo's default) a
 * browser advertising navigator.globalPrivacyControl must be treated exactly
 * like an opt-out — the recorder never starts, so no events are sent.
 *
 * GPC cannot be toggled through standard Playwright APIs, so we stub the
 * property via addInitScript before any page script runs. Primary coverage of
 * the guard logic is the frontend unit test (frontend/test/privacy_test.js);
 * this verifies the end-to-end consequence.
 */
test("a GPC signal prevents any event recording", async ({ page }) => {
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "globalPrivacyControl", {
      value: true,
      configurable: true,
    });
  });

  let posted = false;
  page.on("request", (req) => {
    if (req.url().includes("/sentiero/events") && req.method() === "POST") {
      posted = true;
    }
  });

  await page.goto("/", { waitUntil: "domcontentloaded" });

  // No user input is needed: the GPC guard fires at recorder init, before any
  // interaction, so an active recorder would already have a snapshot to flush.
  // Drive the same tab-hidden flush the recorder listens for; an active
  // recorder would POST here. We expect nothing because it never started.
  await page.evaluate(() => {
    Object.defineProperty(document, "visibilityState", {
      value: "hidden",
      configurable: true,
    });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  await page.waitForTimeout(1000);

  expect(posted).toBe(false);
});
