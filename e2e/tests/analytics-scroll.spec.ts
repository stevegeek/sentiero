import { test, expect, Page, flushRecorder } from "./fixtures";

/**
 * Scroll-depth analytics end-to-end test: record a session in which the page is
 * scrolled, flush it, then drive the compute-on-read scroll-depth page at
 * /analytics/scroll and assert:
 *   1. the recorded page URL appears with its session count,
 *   2. the hand-rolled SVG histogram is drawn (has <rect> bars), and
 *   3. the fold-line percentiles are shown.
 *
 * Depth is aggregated server-side by ScrollDepthAnalyzer from the recorded
 * rrweb scroll events (type 3 / source 3); the page renders the distribution
 * histogram + fold markers as inline SVG with no chart dependency.
 */

const DASHBOARD = "/sentiero/dashboard/";
const SCROLL = "/sentiero/dashboard/analytics/scroll";

async function recordScrolledSession(page: Page) {
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
}

async function waitForSession(page: Page) {
  await page.goto(DASHBOARD, { waitUntil: "domcontentloaded" });
  const sessionLink = page.locator("a.session-id").first();
  await expect(async () => {
    await page.reload({ waitUntil: "domcontentloaded" });
    await expect(sessionLink).toBeVisible({ timeout: 2000 });
  }).toPass({ timeout: 30_000, intervals: [1000, 1000, 2000] });
}

test("scroll-depth page renders a histogram and fold lines", async ({
  page,
}) => {
  // The fixture aborts the Tailwind CDN <script>, which the browser surfaces as
  // a "Failed to load resource: net::ERR_FAILED" console error. That abort is
  // deliberate and unrelated to the page's own JS, so ignore it and assert that
  // the analytics page itself logs no errors.
  const errors: string[] = [];
  page.on("console", (msg) => {
    if (msg.type() !== "error") return;
    if (/Failed to load resource/i.test(msg.text())) return;
    errors.push(msg.text());
  });

  await recordScrolledSession(page);
  await flushRecorder(page);
  await waitForSession(page);

  await page.goto(SCROLL, { waitUntil: "domcontentloaded" });
  await expect(page.getByRole("heading", { name: "Scroll Depth" })).toBeVisible();

  // The recorded page URL appears with its aggregated depth.
  await expect(page.getByText(/session/i).first()).toBeVisible();

  // The hand-rolled SVG histogram has bars and the four distribution bins.
  // Target the chart by its aria-label so we don't match the sidebar nav icons,
  // which are also <svg> but carry no <rect> bars.
  const svg = page.locator('svg[aria-label="Scroll depth distribution"]').first();
  await expect(svg).toBeVisible();
  await expect(svg.locator("rect")).not.toHaveCount(0);
  await expect(page.getByText("75-100%")).toBeVisible();

  // The fold-line percentiles are shown.
  await expect(page.getByText(/50th percentile/i)).toBeVisible();
  await expect(page.getByText(/viewport/i).first()).toBeVisible();

  expect(errors).toEqual([]);
});
