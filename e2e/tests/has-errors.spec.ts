import { test, expect, Page, flushRecorder, gotoApp } from "./fixtures";

/**
 * has-errors end-to-end test: record a session in which a JS error is thrown
 * (the demo's "Trigger error" button has an inline onclick that throws, which
 * fires window's "error" event the recorder listens for). Flush it, then in the
 * dashboard session list assert:
 *   1. the session row shows an "errors" badge, and
 *   2. the "Has errors" filter narrows the list to error sessions only.
 *
 * The demo enables `config.capture_errors = true`, so the events app sets
 * metadata["has_errors"] = true when a batch contains an "error" custom event.
 */

const DASHBOARD = "/sentiero/dashboard/";

async function recordSessionWithError(page: Page) {
  await gotoApp(page);

  // Add a todo so the session has ordinary activity besides the error.
  await page.locator('input[name="text"]').fill("Buy milk");
  await page.getByRole("button", { name: "Add" }).click();
  await expect(page.getByText("Buy milk")).toBeVisible();

  // The inline onclick throws an uncaught Error; Playwright surfaces that as a
  // pageerror but does not fail the test. The recorder's window "error"
  // listener turns it into an rrweb custom event tagged "error".
  const pageError = page.waitForEvent("pageerror");
  await page.locator("#trigger-error-btn").click();
  await pageError;
}

test("session with a JS error shows an errors badge and is filterable", async ({
  page,
}) => {
  await recordSessionWithError(page);

  await flushRecorder(page);

  // Wait for the session row to appear in the dashboard.
  await page.goto(DASHBOARD, { waitUntil: "domcontentloaded" });
  await expect(page).toHaveTitle("Sentiero Dashboard");

  const sessionLink = page.locator("a.session-id").first();
  await expect(async () => {
    await page.reload({ waitUntil: "domcontentloaded" });
    await expect(sessionLink).toBeVisible({ timeout: 2000 });
  }).toPass({ timeout: 30_000, intervals: [1000, 1000, 2000] });

  // The has_errors metadata flag is written when the events batch is saved;
  // poll a few reloads until the errors badge is rendered on the row.
  const errorBadge = page.locator("tr", { has: page.locator("a.session-id") })
    .locator(".badge-danger");
  await expect(async () => {
    await page.reload({ waitUntil: "domcontentloaded" });
    await expect(errorBadge.first()).toBeVisible({ timeout: 2000 });
    await expect(errorBadge.first()).toContainText(/errors/i);
  }).toPass({ timeout: 30_000, intervals: [1000, 1000, 2000] });

  const totalSessions = await page.locator("a.session-id").count();
  expect(totalSessions).toBeGreaterThanOrEqual(1);

  // Apply the "Has errors" filter.
  await page.locator("#has_errors").check();
  await page.getByRole("button", { name: "Filter" }).click();
  await expect(page).toHaveURL(/has_errors=true/);

  // Filter checkbox stays checked, every listed session has the errors badge,
  // and at least one error session is present.
  await expect(page.locator("#has_errors")).toBeChecked();
  const rowsWithLink = page.locator("tr", {
    has: page.locator("a.session-id"),
  });
  const filteredCount = await rowsWithLink.count();
  expect(filteredCount).toBeGreaterThanOrEqual(1);
  // Every remaining row carries the errors badge.
  expect(await rowsWithLink.locator(".badge-danger").count()).toBe(
    filteredCount,
  );
});
