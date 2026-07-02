import { test, expect, Page, flushRecorder, gotoApp } from "./fixtures";

/**
 * Error-discovery end-to-end test: record a session in which a JS error is
 * thrown (the demo's "Trigger error" button), flush it, then drive the
 * "Client JS errors" tab of the unified issues page at /issues?source=client
 * and assert:
 *   1. the captured error message is listed,
 *   2. its detail page lists at least one occurrence linking into the replay, and
 *   3. the "Open in player" link deep-links to the replay window with a ?t=
 *      offset (the same param the player uses to seek to the error).
 *
 * The demo enables `config.capture_errors = true`, so the thrown error becomes
 * an rrweb custom event tagged "error" that ErrorDiscovery groups on read.
 * Client-captured JS errors and server-tracked exceptions share one taxonomy
 * (occurrence/problem/issue) and one page: /issues defaults to the "Server
 * exceptions" tab, ?source=client switches to the browser-error tab the
 * listing links into (/issues/client/:id) for the occurrence table.
 */

const DASHBOARD = "/sentiero/dashboard/";
const CLIENT_ERRORS = "/sentiero/dashboard/issues?source=client";

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

test("client-errors issue page lists the error and links to the replay at the error", async ({
  page,
}) => {
  await recordSessionWithError(page);
  await flushRecorder(page);
  await waitForErrorSession(page);

  await page.goto(CLIENT_ERRORS, { waitUntil: "domcontentloaded" });
  await expect(page.getByRole("heading", { name: "Errors" })).toBeVisible();

  // The demo error message is discovered and grouped in the listing.
  const groupLink = page
    .locator('a[href*="/issues/client/"]')
    .filter({ hasText: /Sentiero e2e demo error/ })
    .first();
  await expect(groupLink).toBeVisible();

  // Drill into the group's detail page, which lists every occurrence.
  await groupLink.click();
  await expect(page.getByText(/Sentiero e2e demo error/).first()).toBeVisible();

  // At least one occurrence links into the replay with a ?t= offset.
  const replayLink = page
    .locator('a[href*="/sessions/"][href*="?t="]')
    .first();
  await expect(replayLink).toBeVisible();

  const href = await replayLink.getAttribute("href");
  expect(href).toMatch(/\/sessions\/[^/]+\/windows\/[^/?]+\?t=\d+/);

  // Following the link reaches the replay page for that window.
  await replayLink.click();
  await expect(page).toHaveURL(/\/sessions\/[^/]+\/windows\/[^/?]+\?t=\d+/);
  await expect(page.locator("#replayer")).toBeAttached();
  await expect(page.locator("#replayer iframe")).toBeAttached({
    timeout: 15_000,
  });
});
