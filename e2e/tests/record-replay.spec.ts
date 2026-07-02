import { test, expect, Page, flushRecorder, gotoApp } from "./fixtures";

/**
 * Baseline end-to-end test: record a session in the demo todo app, flush it
 * to the server, then confirm it shows up in the dashboard and the replay
 * page loads with the rrweb player container present.
 *
 * The demo recorder is configured with flush_interval_ms = 5000, but flushes
 * immediately via sendBeacon when the tab is hidden. `flushRecorder` triggers
 * that hide -> beacon flush deterministically (and waits for the POST), so we
 * never wait the full 5s interval and never rely on a navigation surviving the
 * in-flight beacon.
 */

const DASHBOARD = "/sentiero/dashboard/";

async function recordASession(page: Page) {
  await gotoApp(page);

  // Add a todo -> form submit produces input + mutation + navigation events.
  const todoInput = page.locator('input[name="text"]');
  await todoInput.fill("Buy milk");
  await page.getByRole("button", { name: "Add" }).click();

  // The new todo is rendered after the redirect back to "/".
  await expect(page.getByText("Buy milk")).toBeVisible();

  // Type into a masked text input so there are input events too.
  const maskedInput = page.locator(
    'input[placeholder="Type something here (will be masked in replay)"]',
  );
  await maskedInput.fill("hello world");
}

test("records a session and replays it in the dashboard", async ({ page }) => {
  await recordASession(page);

  // Flush buffered events (tab-hide -> sendBeacon), confirmed by the POST.
  await flushRecorder(page);

  await page.goto(DASHBOARD, { waitUntil: "domcontentloaded" });
  await expect(page).toHaveTitle("Sentiero Dashboard");

  // Poll the dashboard (reloading) until a session row appears. Events POST +
  // file-store write can take a moment after the beacon.
  const sessionLink = page.locator("a.session-id").first();
  await expect(async () => {
    await page.reload({ waitUntil: "domcontentloaded" });
    await expect(sessionLink).toBeVisible({ timeout: 2000 });
  }).toPass({ timeout: 30_000, intervals: [1000, 1000, 2000] });

  expect(await page.locator("a.session-id").count()).toBeGreaterThanOrEqual(1);

  // Click into the session -> replay page.
  await sessionLink.click();

  // The replay page loads with the rrweb player container in the DOM.
  await expect(page.getByText("Session Details")).toBeVisible();
  await expect(page.locator("#replayer")).toBeAttached();

  // rrweb-player renders an iframe inside #replayer once events load.
  await expect(page.locator("#replayer iframe")).toBeAttached({
    timeout: 20_000,
  });
});
