import { test as base, expect } from "@playwright/test";

/**
 * Shared test fixtures.
 *
 * The demo app loads Tailwind from a synchronous <script src="https://cdn.tailwindcss.com">
 * in its <head>. If that CDN is slow or unreachable from the test browser
 * (common in sandboxed/offline CI), DOM parsing blocks on it and even a
 * `domcontentloaded` navigation never resolves. Tailwind is purely cosmetic
 * for these tests (the recorder, forms, and dashboard all work without it),
 * so we abort that request to keep navigations fast and deterministic. We do
 * NOT modify the demo app itself.
 */
export const test = base.extend({
  /**
   * The demo is consent-first: the recorder script tag renders only when the
   * `sentiero_demo_consent=granted` cookie is present (see demo/views/layout.erb).
   * Pre-grant it for every test so recording starts on first load, as the
   * recording specs assume. consent-banner.spec.ts clears cookies to exercise
   * the pre-consent path.
   */
  context: async ({ context, baseURL }, use) => {
    await context.addCookies([
      {
        name: "sentiero_demo_consent",
        value: "granted",
        url: baseURL ?? "http://localhost:9393",
      },
    ]);
    await use(context);
  },
  page: async ({ page }, use) => {
    await page.route(/cdn\.tailwindcss\.com/, (route) => route.abort());
    await use(page);
  },
});

export { expect };
export type { Page } from "@playwright/test";

import type { Page } from "@playwright/test";

const DASHBOARD = "/sentiero/dashboard/";

/**
 * Navigate to the demo's todo app and wait for it to render.
 *
 * The todo app that most recording specs interact with (the
 * `input[name="text"]` + Add form, the masked/blocked privacy-demo sections,
 * the error triggers, the opt-out toggle) is the front page; the scrollable
 * marketing page the scroll/heatmap specs use lives at "/landing". A fresh
 * session (no signup) always renders the "Todo List" heading.
 */
export async function gotoApp(page: Page): Promise<void> {
  await page.goto("/", { waitUntil: "domcontentloaded" });
  await expect(page.getByRole("heading", { name: "Todo List" })).toBeVisible();
}

/**
 * Deterministically flush the recorder's buffered events to the server.
 *
 * In production the recorder flushes via `navigator.sendBeacon` when the tab
 * is hidden or the page unloads. Driving that by navigating the page away is
 * flaky under Playwright — the controlled navigation can abort the in-flight
 * beacon before it reaches the server (net::ERR_ABORTED). Instead we simulate
 * the tab becoming hidden (the same `visibilitychange` -> hidden trigger the
 * recorder listens for) while the page is still alive, and wait for the
 * resulting POST /sentiero/events to complete. No demo changes required.
 */
export async function flushRecorder(page: Page): Promise<void> {
  const responsePromise = page
    .waitForResponse((r) => r.url().includes("/sentiero/events"), {
      timeout: 15_000,
    })
    .catch(() => null);

  await page.evaluate(() => {
    Object.defineProperty(document, "visibilityState", {
      value: "hidden",
      configurable: true,
    });
    document.dispatchEvent(new Event("visibilitychange"));
  });

  const response = await responsePromise;
  if (!response || !response.ok()) {
    throw new Error(
      `recorder flush did not POST a successful /sentiero/events (got ${
        response ? response.status() : "no response"
      })`,
    );
  }
}

/** Count the session links currently rendered on the dashboard listing. */
async function sessionCount(page: Page): Promise<number> {
  await page.goto(DASHBOARD, { waitUntil: "domcontentloaded" });
  return page.locator("a.session-id").count();
}

/**
 * Reload the dashboard until it lists at least `expected` recorded sessions,
 * then return the current count. The listing renders one `a.session-id` link
 * per session (the same anchor the heatmap/segments specs key off). Pass
 * `expected: 0` to assert no session is recorded: the poll returns immediately
 * since the condition already holds, so set the opt-out state and flush first,
 * then assert the returned count is 0.
 */
export async function waitForSessions(
  page: Page,
  expected: number,
): Promise<number> {
  let count = 0;
  await expect(async () => {
    count = await sessionCount(page);
    expect(count).toBeGreaterThanOrEqual(expected);
  }).toPass({ timeout: 30_000, intervals: [500, 1000, 2000] });
  return count;
}

/**
 * Remove every recorded session so a test starts from a clean dashboard.
 *
 * The listing renders a CSRF-guarded bulk-delete form: each row carries a
 * `session_ids[]` checkbox holding the FULL session id (the visible link shows
 * only a truncated id), and the form embeds a `csrf_token` hidden field backed
 * by the `sentiero_csrf` cookie. We read those full ids plus the token and POST
 * the form via the authenticated request context (DashboardApp#handle_bulk_delete
 * validates the token and deletes each `session_ids` value), then wait for the
 * listing to empty. No-op when nothing is recorded.
 */
export async function clearSessions(page: Page): Promise<void> {
  await page.goto(DASHBOARD, { waitUntil: "domcontentloaded" });

  const { ids, csrf } = await page.evaluate(() => {
    const ids = Array.from(
      document.querySelectorAll<HTMLInputElement>(
        'input[name="session_ids[]"]',
      ),
    ).map((input) => input.value);
    const token = document
      .querySelector('input[name="csrf_token"]')
      ?.getAttribute("value");
    return { ids, csrf: token ?? "" };
  });

  if (ids.length === 0) return;

  const body = new URLSearchParams();
  body.append("csrf_token", csrf);
  for (const id of ids) body.append("session_ids[]", id);

  const res = await page.request.post(`${DASHBOARD}sessions/bulk_delete`, {
    headers: { "content-type": "application/x-www-form-urlencoded" },
    data: body.toString(),
  });
  expect(res.ok()).toBe(true);

  // Reload so the assertion runs against the post-delete listing (toHaveCount
  // re-queries the DOM but does not re-navigate).
  await page.goto(DASHBOARD, { waitUntil: "domcontentloaded" });
  await expect(page.locator("a.session-id")).toHaveCount(0, { timeout: 15_000 });
}
