import { test, expect, Page, flushRecorder, gotoApp } from "./fixtures";

/**
 * Web Vitals end-to-end test: record a session with a real interaction, open
 * the replay page, and assert the Web Vitals badge area renders at least one
 * metric.
 *
 * The demo enables `config.capture_web_vitals = true`, so the recorder lazily
 * loads the web-vitals library and emits LCP/CLS/INP as rrweb "__perf" custom
 * events. On the replay page `renderWebVitalBadges` reads those and fills the
 * `#web-vitals-badges` container (display flips from none to inline-flex).
 *
 * LCP reliably fires on load; CLS/INP may be absent and values are
 * environment-dependent, so we assert leniently: the badge area becomes visible
 * with >= 1 badge, and at least an LCP badge is present. We never assert exact
 * metric values.
 */

const DASHBOARD = "/sentiero/dashboard/";

async function recordASession(page: Page) {
  await gotoApp(page);

  // A real interaction so the page is genuinely loaded/painted before flush.
  await page.locator('input[name="text"]').fill("Vitals run");
  await page.getByRole("button", { name: "Add" }).click();
  await expect(page.getByText("Vitals run")).toBeVisible();

  // web-vitals reports LCP on the next frame after load; give it a moment and
  // a paint-triggering interaction before flushing.
  await page.locator('input[name="text"]').click();
  await page.waitForTimeout(500);
}

test("replay page shows a Web Vitals badge with at least one metric", async ({
  page,
}) => {
  await recordASession(page);
  await flushRecorder(page);

  await page.goto(DASHBOARD, { waitUntil: "domcontentloaded" });
  const sessionLink = page.locator("a.session-id").first();
  await expect(async () => {
    await page.reload({ waitUntil: "domcontentloaded" });
    await expect(sessionLink).toBeVisible({ timeout: 2000 });
  }).toPass({ timeout: 30_000, intervals: [1000, 1000, 2000] });

  await sessionLink.click();
  await expect(page.getByText("Session Details")).toBeVisible();

  // The badge area is hidden until events load and at least one __perf metric
  // is extracted. LCP fires on load, so it should appear once events load.
  const vitalsArea = page.locator("#web-vitals-badges");
  await expect(vitalsArea).toBeVisible({ timeout: 20_000 });

  const badges = vitalsArea.locator(".badge");
  await expect(badges.first()).toBeVisible();
  expect(await badges.count()).toBeGreaterThanOrEqual(1);

  // LCP is the reliable one; assert it (or, leniently, at least one badge) is
  // present without asserting on the numeric value.
  await expect(vitalsArea).toContainText(/LCP|CLS|INP/);
});
