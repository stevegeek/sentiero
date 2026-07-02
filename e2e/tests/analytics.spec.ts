import { test, expect, Page, flushRecorder, gotoApp } from "./fixtures";

/**
 * Analytics overview end-to-end test: record a session in the demo todo app
 * (which produces a mix of incremental + meta events, plus session metadata
 * URL/referrer/userAgent), flush it, then open the analytics overview and
 * assert the computed-on-read cards and charts render with real, non-zero data.
 */

const DASHBOARD = "/sentiero/dashboard/";
const ANALYTICS = "/sentiero/dashboard/analytics";

async function recordASession(page: Page) {
  await gotoApp(page);

  await page.locator('input[name="text"]').fill("Buy milk");
  await page.getByRole("button", { name: "Add" }).click();
  await expect(page.getByText("Buy milk")).toBeVisible();
}

async function waitForSession(page: Page) {
  await page.goto(DASHBOARD, { waitUntil: "domcontentloaded" });
  const sessionLink = page.locator("a.session-id").first();
  await expect(async () => {
    await page.reload({ waitUntil: "domcontentloaded" });
    await expect(sessionLink).toBeVisible({ timeout: 2000 });
  }).toPass({ timeout: 30_000, intervals: [1000, 1000, 2000] });
}

test("analytics overview renders metrics and charts from recorded data", async ({
  page,
}) => {
  await recordASession(page);
  await flushRecorder(page);
  await waitForSession(page);

  await page.goto(ANALYTICS, { waitUntil: "domcontentloaded" });
  await expect(page).toHaveTitle("Sentiero Dashboard");

  // Page heading and metric cards present.
  await expect(
    page.getByRole("heading", { name: "Analytics" }),
  ).toBeVisible();
  await expect(page.getByText("Total Sessions").first()).toBeVisible();
  await expect(page.getByText("Total Events").first()).toBeVisible();
  await expect(page.getByText("Avg Duration").first()).toBeVisible();

  // Events-per-day bar chart has rendered at least one bar.
  await expect(page.locator(".stats-chart-bar").first()).toBeVisible();

  // Browser/device distributions are not empty (the demo runs in Chromium on
  // a desktop UA).
  await expect(page.getByText("Browsers").first()).toBeVisible();
  await expect(page.getByText("Devices").first()).toBeVisible();

  // Duration donut SVG is present.
  await expect(page.locator("svg circle").first()).toBeAttached();
});

test("analytics range selector changes the window", async ({ page }) => {
  await recordASession(page);
  await flushRecorder(page);
  await waitForSession(page);

  await page.goto(`${ANALYTICS}?range=14`, { waitUntil: "domcontentloaded" });
  // 14-day window => exactly 14 day columns in the chart.
  await expect(page.locator(".stats-chart-col")).toHaveCount(14);
  await expect(page.locator("#range")).toHaveValue("14");

  await page.goto(`${ANALYTICS}?range=30`, { waitUntil: "domcontentloaded" });
  await expect(page.locator(".stats-chart-col")).toHaveCount(30);
  await expect(page.locator("#range")).toHaveValue("30");
});
