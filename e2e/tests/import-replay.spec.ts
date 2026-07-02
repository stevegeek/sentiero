import { test, expect, Page, flushRecorder, gotoApp } from "./fixtures";

/**
 * Phase 3 — play-from-JSON import page.
 *
 * The demo app enables `shareable_replays`, so /analytics/import renders a page
 * that lets an operator paste a session events JSON file and replays it
 * client-side in rrweb-player with NO server round-trip for the replay.
 *
 * To exercise it with realistic data we first record a session, fetch its real
 * events JSON (the same array the import page expects) via the dashboard's
 * events API, then paste that into the import textarea, click Replay, and
 * assert the rrweb-player mounts an iframe.
 *
 * The flag-disabled case (page 404s) cannot be exercised here because the e2e
 * demo server's config is fixed; it is covered by the Ruby handler test.
 */

const DASHBOARD = "/sentiero/dashboard/";
const IMPORT = "/sentiero/dashboard/analytics/import";

async function recordSession(page: Page): Promise<string> {
  await gotoApp(page);

  await page.locator('input[name="text"]').fill("Buy milk");
  await page.getByRole("button", { name: "Add" }).click();
  await expect(page.getByText("Buy milk")).toBeVisible();

  await flushRecorder(page);

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

// Fetch the recorded session's events array via the dashboard events API,
// using the eventsUrl the replay page embeds in its #sentiero-player-config.
async function fetchSessionEvents(
  page: Page,
  sessionId: string,
): Promise<unknown[]> {
  await page.goto(`${DASHBOARD}sessions/${sessionId}`, {
    waitUntil: "domcontentloaded",
  });
  const eventsUrl = await page.evaluate(() => {
    const el = document.getElementById("sentiero-player-config");
    if (!el) return null;
    return (JSON.parse(el.textContent || "{}") as { eventsUrl?: string })
      .eventsUrl;
  });
  expect(eventsUrl, "eventsUrl from player config").toBeTruthy();

  const response = await page.request.get(eventsUrl as string);
  expect(response.ok()).toBeTruthy();
  const events = (await response.json()) as unknown[];
  expect(events.length).toBeGreaterThan(1);
  return events;
}

test("import page replays a pasted events JSON entirely client-side", async ({
  page,
}) => {
  const sessionId = await recordSession(page);
  const events = await fetchSessionEvents(page, sessionId);

  await page.goto(IMPORT, { waitUntil: "domcontentloaded" });
  await expect(
    page.getByRole("heading", { name: "Import Replay" }),
  ).toBeVisible();

  // Paste the events JSON and trigger a client-side replay. Setting .value
  // directly avoids typing a large JSON blob char by char.
  const textarea = page.locator("#import-textarea");
  await textarea.evaluate(
    (el, json) => {
      (el as HTMLTextAreaElement).value = json;
    },
    JSON.stringify(events),
  );

  await page.getByRole("button", { name: "Replay" }).click();

  // rrweb-player mounts an iframe inside the player container once it replays.
  await expect(page.locator("#import-player iframe")).toBeAttached({
    timeout: 20_000,
  });

  // The status line confirms the parsed event count, proving the client-side
  // parse/validate/mount path ran (no server round-trip for the replay).
  await expect(page.locator("#import-status")).toContainText(/Replaying \d+/);
});

test("import page shows a friendly error for invalid JSON", async ({
  page,
}) => {
  await page.goto(IMPORT, { waitUntil: "domcontentloaded" });
  await expect(
    page.getByRole("heading", { name: "Import Replay" }),
  ).toBeVisible();

  await page.locator("#import-textarea").fill("not json at all");
  await page.getByRole("button", { name: "Replay" }).click();

  await expect(page.locator("#import-status")).toContainText(
    "valid JSON",
  );
  // No player should have mounted for invalid input.
  await expect(page.locator("#import-player iframe")).toHaveCount(0);
});
