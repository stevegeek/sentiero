import { test, expect, Page, flushRecorder, gotoApp } from "./fixtures";

/**
 * Phase 3 — standalone self-contained HTML shareable replay.
 *
 * The demo app enables `shareable_replays`, so the session replay page exposes
 * a "Download HTML" link to /analytics/share/:id and that route returns a
 * single self-contained HTML document (inlined rrweb-player + events). These
 * tests record a real session, then assert the link is present and the route
 * downloads an HTML attachment containing the inline player + events blob.
 *
 * The flag-disabled cases (404 + link hidden) cannot be exercised here because
 * the e2e demo server's config is fixed; they are covered by the Ruby handler
 * tests instead.
 */

const DASHBOARD = "/sentiero/dashboard/";

async function recordSession(page: Page): Promise<string> {
  await gotoApp(page);

  await page.locator('input[name="text"]').fill("Buy milk");
  await page.getByRole("button", { name: "Add" }).click();
  await expect(page.getByText("Buy milk")).toBeVisible();

  await flushRecorder(page);

  // Poll the dashboard until the recorded session row appears, then read its id
  // from the replay link href (/sentiero/dashboard/sessions/<id>).
  await page.goto(DASHBOARD, { waitUntil: "domcontentloaded" });
  const sessionLink = page.locator("a.session-id").first();
  await expect(async () => {
    await page.reload({ waitUntil: "domcontentloaded" });
    await expect(sessionLink).toBeVisible({ timeout: 2000 });
  }).toPass({ timeout: 30_000, intervals: [1000, 1000, 2000] });

  const href = await sessionLink.getAttribute("href");
  const id = href?.split("/sessions/")[1];
  expect(id, "session id parsed from session link href").toBeTruthy();
  return id as string;
}

test("session replay page exposes a Download HTML link when shareable_replays is enabled", async ({
  page,
}) => {
  const sessionId = await recordSession(page);

  await page.goto(`${DASHBOARD}sessions/${sessionId}`, {
    waitUntil: "domcontentloaded",
  });
  await expect(page.getByText("Session Details")).toBeVisible();

  const shareLink = page.locator(
    `a[href$="/analytics/share/${sessionId}"]`,
  );
  await expect(shareLink).toBeVisible();
  await expect(shareLink).toContainText("Download HTML");
});

test("share route downloads a self-contained HTML file with inline player and events", async ({
  page,
  request,
}) => {
  const sessionId = await recordSession(page);

  // The `request` fixture inherits the project's httpCredentials (demo/demo).
  const response = await request.get(
    `${DASHBOARD}analytics/share/${sessionId}`,
  );

  expect(response.status()).toBe(200);
  expect(response.headers()["content-type"]).toContain("text/html");
  expect(response.headers()["content-disposition"]).toContain("attachment");
  expect(response.headers()["content-disposition"]).toContain(
    `session-${sessionId}.html`,
  );

  const body = await response.text();
  // The player runtime is inlined (esbuild global name), as is the events blob
  // and the container the bootloader mounts the player into.
  expect(body).toContain("rrwebPlayer");
  expect(body).toContain('id="sentiero-events"');
  expect(body).toContain('id="sentiero-player"');
});

test("share route 404s for an unknown session", async ({ request }) => {
  const response = await request.get(
    `${DASHBOARD}analytics/share/no-such-session`,
  );
  expect(response.status()).toBe(404);
});
