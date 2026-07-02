import { test, expect, Page, flushRecorder } from "./fixtures";

/**
 * Click-heatmap end-to-end test: record a session with several clicks spread
 * across the demo's landing page, flush it, then drive the compute-on-read
 * heatmap page at /analytics/heatmap and assert:
 *   1. the recorded page URL appears in the picker,
 *   2. the density canvas is drawn (non-empty pixels), and
 *   3. the top-clicked-elements table lists at least one element.
 *
 * The demo enables `config.capture_clicks = true`; a global capture-phase
 * click listener (recorder.js) fires a "__click" custom event carrying a CSS
 * selector for EVERY click, not just tracked ones, so clicking ordinary page
 * content works just as well as clicking a button. The landing page is long
 * and its clickable/inert elements sit far apart vertically, so clicking a
 * spread of them (each auto-scrolled into view first) gives the density grid
 * genuinely distinct coordinates rather than repeated clicks on one spot.
 * "Watch the demo" is a real inert <button> (no handler, no navigation, see
 * demo/views/landing.erb) so it also satisfies the top-elements table's
 * expectation of a <button> selector; the headings clicked after it are
 * plain content and never navigate away, so the buffered clicks survive to
 * be flushed.
 */

const DASHBOARD = "/sentiero/dashboard/";
const HEATMAP = "/sentiero/dashboard/analytics/heatmap";

async function recordSessionWithClicks(page: Page) {
  await page.goto("/", { waitUntil: "domcontentloaded" });
  await expect(page).toHaveTitle(/Trailhead/);

  await page.getByRole("button", { name: "Watch the demo" }).click();
  await page.getByRole("heading", { name: "Capture in seconds" }).click();
  await page.getByRole("heading", { name: "Done feels good" }).click();
  await page.getByRole("heading", { name: "Ready to hit the trail?" }).click();
}

async function waitForSession(page: Page) {
  await page.goto(DASHBOARD, { waitUntil: "domcontentloaded" });
  const sessionLink = page.locator("a.session-id").first();
  await expect(async () => {
    await page.reload({ waitUntil: "domcontentloaded" });
    await expect(sessionLink).toBeVisible({ timeout: 2000 });
  }).toPass({ timeout: 30_000, intervals: [1000, 1000, 2000] });
}

test("heatmap page renders a density canvas and top-clicked elements", async ({
  page,
}) => {
  await recordSessionWithClicks(page);
  await flushRecorder(page);
  await waitForSession(page);

  await page.goto(HEATMAP, { waitUntil: "domcontentloaded" });
  await expect(page.getByRole("heading", { name: "Click Heatmaps" })).toBeVisible();

  // The recorded page URL is offered in the picker.
  const picker = page.locator("select[name='url']");
  await expect(picker).toBeVisible();
  await expect(picker.locator("option")).not.toHaveCount(0);

  // The status line reports aggregated clicks once the JSON has loaded.
  await expect(page.locator("#heatmap-status")).toContainText(/clicks/i, {
    timeout: 20_000,
  });

  // The canvas has non-empty pixels (the density grid was drawn).
  const hasPixels = await page.evaluate(() => {
    const canvas = document.getElementById(
      "heatmap-canvas",
    ) as HTMLCanvasElement | null;
    if (!canvas || canvas.width === 0 || canvas.height === 0) return false;
    const ctx = canvas.getContext("2d");
    if (!ctx) return false;
    const { data } = ctx.getImageData(0, 0, canvas.width, canvas.height);
    for (let i = 3; i < data.length; i += 4) {
      if (data[i] !== 0) return true; // any non-transparent pixel
    }
    return false;
  });
  expect(hasPixels).toBe(true);

  // The top-clicked-elements table lists at least one element.
  const rows = page.locator("#heatmap-top-elements tr");
  await expect(rows.first()).toBeVisible();
  await expect(page.locator("#heatmap-top-elements")).toContainText(/button/i);
});
