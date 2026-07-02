import { test, expect, Page, flushRecorder, gotoApp } from "./fixtures";

/**
 * Click-overlay end-to-end test: record a session with several clicks, open the
 * replay page, click the toolbar "Clicks" toggle, and assert click dots appear
 * overlaid on the player. Toggling off removes them.
 *
 * The toggle button is `#toggle-clicks-btn` (data-action="toggle-clicks"); when
 * enabled, `click_overlay.js` appends a `.click-overlay-container` holding one
 * `.click-dot` per recorded mouse-click event into the player wrapper.
 */

const DASHBOARD = "/sentiero/dashboard/";

async function recordClicks(page: Page) {
  await gotoApp(page);

  // Generate several recorded clicks at distinct spots. Adding a todo plus
  // clicking the Add button / input produces type-3/source-2 click events.
  const input = page.locator('input[name="text"]');
  const addBtn = page.getByRole("button", { name: "Add" });
  await input.fill("Click one");
  await addBtn.click();
  await expect(page.getByText("Click one")).toBeVisible();

  await input.click();
  await input.fill("Click two");
  await addBtn.click();
  await expect(page.getByText("Click two")).toBeVisible();

  await input.click();
}

test("click overlay toggle shows and hides click dots on the replay", async ({
  page,
}) => {
  await recordClicks(page);
  await flushRecorder(page);

  await page.goto(DASHBOARD, { waitUntil: "domcontentloaded" });
  const sessionLink = page.locator("a.session-id").first();
  await expect(async () => {
    await page.reload({ waitUntil: "domcontentloaded" });
    await expect(sessionLink).toBeVisible({ timeout: 2000 });
  }).toPass({ timeout: 30_000, intervals: [1000, 1000, 2000] });

  await sessionLink.click();
  await expect(page.getByText("Session Details")).toBeVisible();

  // Wait for the player to mount (overlay needs the player instance + events).
  await expect(page.locator("#replayer iframe")).toBeAttached({
    timeout: 20_000,
  });

  const toggle = page.locator("#toggle-clicks-btn");
  await expect(toggle).toBeVisible();
  await expect(toggle).toHaveAttribute("aria-pressed", "false");

  const dots = page.locator("#replayer .click-overlay-container .click-dot");

  // Toggle on: the overlay container with click dots is injected. The overlay
  // only renders once the player is ready, so poll the toggle until dots show.
  await expect(async () => {
    if ((await dots.count()) === 0) {
      await toggle.click();
    }
    await expect(dots.first()).toBeAttached({ timeout: 2000 });
  }).toPass({ timeout: 20_000, intervals: [500, 1000, 2000] });

  expect(await dots.count()).toBeGreaterThanOrEqual(1);
  await expect(toggle).toHaveAttribute("aria-pressed", "true");

  // Toggle off: dots are removed.
  await toggle.click();
  await expect(page.locator("#replayer .click-overlay-container")).toHaveCount(
    0,
  );
  await expect(toggle).toHaveAttribute("aria-pressed", "false");
});
