import { test, expect, flushRecorder } from "./fixtures";

/**
 * Frustration annotations: record a session containing a rage-click burst
 * (several rapid clicks at the same spot on an element that does nothing),
 * flush it, open the replay page, and confirm a "Rage click" annotation is
 * injected into the activity sidebar entirely client-side. Then confirm that
 * clicking the annotation does not error and the player is present.
 *
 * The landing page ships a purpose-built inert element for this: the "Watch
 * the demo" button has no handler and no navigation (see demo/views/landing.erb),
 * so rage-clicking it is the real dead-click scenario rather than a synthetic
 * stand-in.
 */

const DASHBOARD = "/sentiero/dashboard/";

test("shows frustration annotations in the replay sidebar", async ({ page }) => {
  await page.goto("/landing", { waitUntil: "domcontentloaded" });
  await expect(page).toHaveTitle(/Trailhead/);

  // Rage-click the inert "Watch the demo" button so rrweb records >3 mouse
  // clicks within 500ms at the same coordinates and no mutation follows.
  const target = page.getByRole("button", { name: "Watch the demo" });
  for (let i = 0; i < 5; i++) {
    await target.click({ position: { x: 10, y: 10 }, force: true });
  }

  await flushRecorder(page);

  await page.goto(DASHBOARD, { waitUntil: "domcontentloaded" });
  const sessionLink = page.locator("a.session-id").first();
  await expect(async () => {
    await page.reload({ waitUntil: "domcontentloaded" });
    await expect(sessionLink).toBeVisible({ timeout: 2000 });
  }).toPass({ timeout: 30_000, intervals: [1000, 1000, 2000] });

  await sessionLink.click();
  await expect(page.getByText("Session Details")).toBeVisible();

  // The activity sidebar gets a frustration entry computed client-side from
  // the recorded clicks.
  const entry = page.locator(".activity-entry.frustration-entry").first();
  await expect(entry).toBeVisible({ timeout: 20_000 });
  await expect(entry).toContainText(/Rage click/);

  // Clicking the annotation seeks the player without error.
  await entry.click();
  await expect(page.locator("#replayer")).toBeVisible();
});
