import { test, expect, Page, flushRecorder, gotoApp } from "./fixtures";

/**
 * Segments end-to-end test: record a session in the demo (Chromium / desktop
 * UA) that also throws a JS error, flush it, then drive the compute-on-read
 * segmentation page at /analytics/segments and assert each filter narrows the
 * matching session list as expected:
 *   - browser = Chrome             -> session is listed
 *   - device  = Mobile             -> session is excluded (demo is desktop)
 *   - has_errors                   -> session is listed (it threw an error)
 *   - browser = Chrome + has_errors (AND) -> still listed
 *
 * The demo enables `config.capture_errors = true`, so the error session gets
 * metadata["has_errors"] = true once its batch is saved.
 */

const DASHBOARD = "/sentiero/dashboard/";
const SEGMENTS = "/sentiero/dashboard/analytics/segments";

async function recordSessionWithError(page: Page) {
  await gotoApp(page);

  await page.locator('input[name="text"]').fill("Buy milk");
  await page.getByRole("button", { name: "Add" }).click();
  await expect(page.getByText("Buy milk")).toBeVisible();

  const pageError = page.waitForEvent("pageerror");
  await page.locator("#trigger-error-btn").click();
  await pageError;
}

async function waitForErrorSession(page: Page) {
  await page.goto(DASHBOARD, { waitUntil: "domcontentloaded" });
  const errorBadge = page
    .locator("tr", { has: page.locator("a.session-id") })
    .locator(".badge-danger");
  await expect(async () => {
    await page.reload({ waitUntil: "domcontentloaded" });
    await expect(errorBadge.first()).toBeVisible({ timeout: 2000 });
  }).toPass({ timeout: 30_000, intervals: [1000, 1000, 2000] });
}

function rowsWithSession(page: Page) {
  return page.locator("tr", { has: page.locator("a.session-id") });
}

test("segments page filters the session population on read", async ({
  page,
}) => {
  await recordSessionWithError(page);
  await flushRecorder(page);
  await waitForErrorSession(page);

  // Filter form is present.
  await page.goto(SEGMENTS, { waitUntil: "domcontentloaded" });
  await expect(page.getByRole("heading", { name: "Segments" })).toBeVisible();
  await expect(page.locator("#browser")).toBeVisible();
  await expect(page.locator("#device")).toBeVisible();
  await expect(page.locator("#has_errors")).toBeVisible();

  // browser = Chrome -> the demo session (Chromium) is listed.
  await page.selectOption("#browser", "Chrome");
  await page.getByRole("button", { name: "Filter" }).click();
  await expect(page).toHaveURL(/browser=Chrome/);
  await expect(page.locator("#browser")).toHaveValue("Chrome");
  expect(await rowsWithSession(page).count()).toBeGreaterThanOrEqual(1);

  // device = Mobile -> the desktop demo session is excluded.
  await page.goto(`${SEGMENTS}?device=Mobile`, {
    waitUntil: "domcontentloaded",
  });
  await expect(page.getByText("No sessions matched")).toBeVisible();

  // has_errors -> the error session is listed and carries the errors badge.
  await page.goto(`${SEGMENTS}?has_errors=true`, {
    waitUntil: "domcontentloaded",
  });
  await expect(page.locator("#has_errors")).toBeChecked();
  const errorRows = rowsWithSession(page);
  const errorCount = await errorRows.count();
  expect(errorCount).toBeGreaterThanOrEqual(1);
  expect(await errorRows.locator(".badge-danger").count()).toBe(errorCount);

  // AND logic: Chrome + has_errors still lists the error session.
  await page.goto(`${SEGMENTS}?browser=Chrome&has_errors=true`, {
    waitUntil: "domcontentloaded",
  });
  expect(await rowsWithSession(page).count()).toBeGreaterThanOrEqual(1);
});
