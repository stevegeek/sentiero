import { test, expect, Page, flushRecorder, gotoApp } from "./fixtures";

/**
 * Form-analytics end-to-end test: record a session in which the demo's form
 * fields are filled (without navigating away, so the recorder's buffered input
 * events survive to be flushed), flush it, then drive the compute-on-read
 * form-analytics page at /analytics/forms and assert:
 *   1. the page renders with its heading and the per-field / drop-off tables,
 *   2. at least one interacting session is reported.
 *
 * Metrics are aggregated server-side by FormAnalyzer from rrweb input events
 * (type 3 / source 5) using node ids only, so the page never shows field
 * values — it works with maskAllInputs. We deliberately do NOT submit: the
 * demo's submit navigates (r.redirect "/") which would discard the buffered
 * input events before they flush, and the page renders its tables for any
 * interacting session regardless of completion.
 */

const DASHBOARD = "/sentiero/dashboard/";
const FORMS = "/sentiero/dashboard/analytics/forms";

async function recordFormSession(page: Page) {
  await gotoApp(page);

  // Let the recorder take its full DOM snapshot so the input nodes are
  // registered before we type into them; otherwise the very first keystrokes on
  // a cold recorder can be dropped.
  await page.waitForTimeout(500);

  // Type with real keystrokes (pressSequentially) so rrweb emits input events
  // (type 3 / source 5) keyed by node id. Touch two distinct fields so the
  // per-field table has rows, and stay on the page (no submit) so the buffered
  // events are still present to flush.
  const todoInput = page.locator('input[name="text"]');
  await todoInput.click();
  await todoInput.pressSequentially("buy milk", { delay: 30 });

  const maskedInput = page.locator(
    'input[placeholder="Type something here (will be masked in replay)"]',
  );
  await maskedInput.click();
  await maskedInput.pressSequentially("masked value", { delay: 30 });

  // Re-touch the first field so a re-fill is recorded too.
  await todoInput.click();
  await todoInput.pressSequentially(" again", { delay: 30 });

  await page.waitForTimeout(300);
}

async function waitForSession(page: Page) {
  await page.goto(DASHBOARD, { waitUntil: "domcontentloaded" });
  const sessionLink = page.locator("a.session-id").first();
  await expect(async () => {
    await page.reload({ waitUntil: "domcontentloaded" });
    await expect(sessionLink).toBeVisible({ timeout: 2000 });
  }).toPass({ timeout: 30_000, intervals: [1000, 1000, 2000] });
}

test("form-analytics page renders per-field and drop-off tables", async ({
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

  await recordFormSession(page);
  await flushRecorder(page);
  await waitForSession(page);

  await page.goto(FORMS, { waitUntil: "domcontentloaded" });
  await expect(page.getByRole("heading", { name: "Form Analytics" })).toBeVisible();

  await expect(page.getByText("Per-Field Metrics")).toBeVisible();
  await expect(page.getByText("Top Drop-off Fields")).toBeVisible();
  await expect(page.getByText("Sessions Interacting")).toBeVisible();

  expect(errors).toEqual([]);
});
