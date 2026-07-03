import { test, expect, gotoApp } from "./fixtures";

/**
 * Server-side error reporting end-to-end test.
 *
 * The front page's "Trigger server error" button POSTs to /boom, which raises
 * on purpose. The demo's Roda error_handler reports the exception through
 * Sentiero::Reporter to the demo's own ingest endpoint (ErrorsApp), renders a
 * friendly page, and the dashboard groups the occurrence into a problem on
 * the Issues tab. Reporter dispatch is async, so the Issues assertion polls.
 */

const ISSUES = "/sentiero/dashboard/issues";

test("a triggered server error appears in the dashboard Issues list", async ({
  page,
}) => {
  await gotoApp(page);
  await page.locator("#trigger-server-error-btn").click();

  await expect(
    page.getByRole("heading", { name: /Server error/ }),
  ).toBeVisible();

  await expect(async () => {
    await page.goto(ISSUES, { waitUntil: "domcontentloaded" });
    await expect(
      page.getByText("Trailhead demo error").first(),
    ).toBeVisible({ timeout: 1_000 });
  }).toPass({ timeout: 20_000, intervals: [500, 1000, 2000] });
});
