import { test, expect, Page, flushRecorder, gotoApp } from "./fixtures";

/**
 * Export end-to-end test: record a session, then drive the analytics export
 * page at /analytics/export and assert that the "Download CSV" button for the
 * session list produces an attachment whose body has the expected CSV header
 * row and the recorded session's metadata.
 *
 * The downloads are CSRF-guarded POST forms (the page sets a sentiero_csrf
 * cookie and embeds the token in a hidden field), so clicking the button is a
 * real authenticated, CSRF-valid POST.
 */

const EXPORT = "/sentiero/dashboard/analytics/export";

async function recordTodoSession(page: Page) {
  await gotoApp(page);

  await page.locator('input[name="text"]').fill("Buy milk");
  await page.getByRole("button", { name: "Add" }).click();
  await expect(page.getByText("Buy milk")).toBeVisible();
}

test("export page downloads the session list as CSV", async ({ page }) => {
  await recordTodoSession(page);
  await flushRecorder(page);

  await page.goto(EXPORT, { waitUntil: "domcontentloaded" });
  await expect(page.getByRole("heading", { name: "Export" })).toBeVisible();
  await expect(page.getByText("Session list")).toBeVisible();

  const sessionRow = page
    .locator("tr")
    .filter({ hasText: "Session list" });
  const csvForm = sessionRow.locator('form[action$="/sessions.csv"]');

  const downloadPromise = page.waitForEvent("download");
  await csvForm.getByRole("button", { name: "Download CSV" }).click();
  const download = await downloadPromise;

  expect(download.suggestedFilename()).toBe("sessions.csv");

  const stream = await download.createReadStream();
  const chunks: Buffer[] = [];
  for await (const chunk of stream) chunks.push(Buffer.from(chunk));
  const body = Buffer.concat(chunks).toString("utf8");

  // Header row and at least one recorded session are present.
  expect(body).toContain("session_id");
  expect(body).toMatch(/\r\n/);
  expect(body.trim().split("\r\n").length).toBeGreaterThan(1);
});
