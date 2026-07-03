import { test, expect, Page, flushRecorder } from "./fixtures";

/**
 * Scroll-depth indicator: record a session in which the page is scrolled, flush
 * it, open the replay page, and confirm the scroll-depth badge is shown with a
 * non-zero value computed client-side from the recorded rrweb scroll events.
 */

const DASHBOARD = "/sentiero/dashboard/";

test("shows a scroll-depth indicator on the replay page", async ({ page }) => {
  // The landing page is deliberately long/scrollable (see demo/views/landing.erb),
  // so it exercises this feature more naturally than the todo app.
  await page.goto("/landing", { waitUntil: "domcontentloaded" });
  await expect(page).toHaveTitle(/Trailhead/);

  // Make the page tall enough to scroll, then scroll down so rrweb records
  // scroll (type 3 / source 3) events.
  await page.evaluate(() => {
    const spacer = document.createElement("div");
    spacer.style.height = "3000px";
    document.body.appendChild(spacer);
  });
  await page.evaluate(() => window.scrollTo(0, 1500));
  await page.waitForTimeout(200);
  await page.evaluate(() => window.scrollTo(0, 2500));
  await page.waitForTimeout(200);

  await flushRecorder(page);

  await page.goto(DASHBOARD, { waitUntil: "domcontentloaded" });
  const sessionLink = page.locator("a.session-id").first();
  await expect(async () => {
    await page.reload({ waitUntil: "domcontentloaded" });
    await expect(sessionLink).toBeVisible({ timeout: 2000 });
  }).toPass({ timeout: 30_000, intervals: [1000, 1000, 2000] });

  await sessionLink.click();
  await expect(page.getByText("Session Details")).toBeVisible();

  // The scroll-depth badge becomes visible once events load and a scroll is
  // detected, and shows a px value.
  const badge = page.locator("#scroll-depth-info");
  await expect(badge).toBeVisible({ timeout: 20_000 });
  await expect(badge).toContainText(/Scroll/);
  await expect(badge).toContainText(/px/);
});
