import {
  test,
  expect,
  waitForSessions,
  clearSessions,
  flushRecorder,
} from "./fixtures";

/**
 * Consent-first recording end-to-end test.
 *
 * The demo gates the recorder script tag on a `sentiero_demo_consent=granted`
 * cookie (demo/views/layout.erb), implementing the consent-first recipe from
 * the docs (/guide/consent/): before a decision the banner shows and no
 * recorder runs — no script tag, no events POST, no session. Declining
 * persists across reloads; accepting reloads the page with the script tag
 * rendered and recording live.
 *
 * The shared fixture pre-grants consent so the other specs record from first
 * load; every test here clears cookies to get the pre-consent state back.
 */

const BANNER = "#consent-banner";
const RECORDER_CONFIG = "#sentiero-config"; // rendered only with the script tag

test.describe("consent banner", () => {
  test.beforeEach(async ({ page, context }) => {
    await clearSessions(page);
    await context.clearCookies();
  });

  test("shows the banner and does not record before a decision", async ({
    page,
  }) => {
    let posted = false;
    page.on("request", (req) => {
      if (req.url().includes("/sentiero/events") && req.method() === "POST") {
        posted = true;
      }
    });

    await page.goto("/", { waitUntil: "domcontentloaded" });
    await expect(page.locator(BANNER)).toBeVisible();
    await expect(page.locator(RECORDER_CONFIG)).toHaveCount(0);

    // Drive the tab-hidden flush an active recorder would respond to; nothing
    // may leave the browser because the recorder never started.
    await page.evaluate(() => {
      Object.defineProperty(document, "visibilityState", {
        value: "hidden",
        configurable: true,
      });
      document.dispatchEvent(new Event("visibilitychange"));
    });
    await page.waitForTimeout(1000);

    expect(posted).toBe(false);
    expect(await waitForSessions(page, 0)).toBe(0);
  });

  test("declining hides the banner, persists, and records nothing", async ({
    page,
  }) => {
    await page.goto("/", { waitUntil: "domcontentloaded" });
    await page.getByRole("button", { name: "Decline" }).click();
    await expect(page.locator(BANNER)).toHaveCount(0);

    // The decision is remembered: no banner and no recorder on the next load.
    await page.goto("/", { waitUntil: "domcontentloaded" });
    await expect(page.locator(BANNER)).toHaveCount(0);
    await expect(page.locator(RECORDER_CONFIG)).toHaveCount(0);

    await page.locator('input[name="text"]').fill("Not recorded");
    await page.getByRole("button", { name: "Add" }).click();
    await expect(page.getByText("Not recorded")).toBeVisible();
    await page.waitForTimeout(1000);

    expect(await waitForSessions(page, 0)).toBe(0);
  });

  test("accepting starts recording and a session reaches the dashboard", async ({
    page,
  }) => {
    await page.goto("/", { waitUntil: "domcontentloaded" });
    await page.getByRole("button", { name: "Accept & record" }).click();

    // Accepting reloads so the server renders the gated script tag.
    await expect(page.locator(RECORDER_CONFIG)).toHaveCount(1);
    await expect(page.locator(BANNER)).toHaveCount(0);

    await page.locator('input[name="text"]').fill("Recorded after consent");
    await page.getByRole("button", { name: "Add" }).click();
    await expect(page.getByText("Recorded after consent")).toBeVisible();
    await flushRecorder(page);

    expect(await waitForSessions(page, 1)).toBeGreaterThanOrEqual(1);
  });
});
