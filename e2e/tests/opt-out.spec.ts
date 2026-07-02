import {
  test,
  expect,
  waitForSessions,
  clearSessions,
  flushRecorder,
  gotoApp,
} from "./fixtures";

/**
 * End-user opt-out end-to-end test.
 *
 * The demo enables `config.user_opt_out = true`, which exposes the imperative
 * `window.Sentiero.optOut()` / `optIn()` API. The recorder evaluates the
 * opt-out signal once at page load (recorder.js, before rrweb starts), so an
 * opted-out page produces no events, makes no /sentiero/events request, and
 * creates no session. Opting back in and reloading starts the recorder again.
 *
 * The dashboard session count is the authoritative signal here, so the
 * opted-out cases deliberately do NOT call flushRecorder (an opted-out page
 * never POSTs, so waiting for that POST would time out).
 */

const OPT_OUT_COOKIE = "sentiero_optout"; // Configuration#opt_out_cookie_name default.

async function addTodo(page, text: string) {
  await gotoApp(page);
  await page.locator('input[name="text"]').fill(text);
  await page.getByRole("button", { name: "Add" }).click();
  await expect(page.getByText(text)).toBeVisible();
}

test.describe("end-user opt-out", () => {
  test.beforeEach(async ({ page }) => {
    await clearSessions(page);
  });

  test("no session is recorded when opted out before the page loads", async ({
    page,
    context,
  }) => {
    // Opt out via the opt-out cookie before the first navigation so the recorder
    // sees the signal at startup and never begins recording.
    await context.addCookies([
      { name: OPT_OUT_COOKIE, value: "1", url: "http://localhost:9393" },
    ]);

    await addTodo(page, "Buy milk");

    // Drive the same visibilitychange that would normally flush the recorder,
    // giving an opted-out page every chance to (wrongly) send something.
    await page.evaluate(() => {
      Object.defineProperty(document, "visibilityState", {
        value: "hidden",
        configurable: true,
      });
      document.dispatchEvent(new Event("visibilitychange"));
    });
    await page.waitForTimeout(1000);

    expect(await waitForSessions(page, 0)).toBe(0);
  });

  test("recording resumes after opting back in", async ({ page, context }) => {
    // Opt out via cookie before the first navigation so the initial load never
    // records.
    await context.addCookies([
      { name: OPT_OUT_COOKIE, value: "1", url: "http://localhost:9393" },
    ]);

    await addTodo(page, "Task A");
    await page.waitForTimeout(1000);
    expect(await waitForSessions(page, 0)).toBe(0);

    // Opt back in via the JS API (clears the cookie + localStorage), reload so
    // the recorder starts, and interact again.
    await page.goto("/", { waitUntil: "domcontentloaded" });
    await page.evaluate(() => window.Sentiero.optIn());
    await addTodo(page, "Task B");
    await flushRecorder(page);

    expect(await waitForSessions(page, 1)).toBeGreaterThanOrEqual(1);
  });
});
