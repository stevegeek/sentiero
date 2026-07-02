import { test, expect, Page, flushRecorder, gotoApp } from "./fixtures";

/**
 * Form-interaction end-to-end test: record a session filling more than one form
 * field, open the replay page, and assert the activity sidebar surfaces the
 * form-interaction detail for input entries.
 *
 * `form-interaction.js` analyses rrweb input events (type 3 / source 5) by node
 * id and attaches detail lines ("Field N of M", optional re-fill/time-to-next)
 * to each input significant event. Those lines render inside the input entry's
 * `.activity-detail` panel in the activity sidebar. This works under
 * maskAllInputs (it keys on node id, never values), so we do not depend on the
 * masked text content.
 */

const DASHBOARD = "/sentiero/dashboard/";

async function recordFormFilling(page: Page) {
  await gotoApp(page);

  // Fill the todo text input (field 1).
  const todoInput = page.locator('input[name="text"]');
  await todoInput.click();
  await todoInput.fill("a task");

  // Fill the masked text input (field 2) so there are >= 2 distinct fields and
  // the detail reports "Field 1 of 2" / "Field 2 of 2".
  const maskedInput = page.locator(
    'input[placeholder="Type something here (will be masked in replay)"]',
  );
  await maskedInput.click();
  await maskedInput.fill("masked value");

  // Re-fill field 1 so the re-fill counter has something to report too.
  await todoInput.click();
  await todoInput.fill("a task edited");
}

test("activity sidebar shows form-interaction detail for input entries", async ({
  page,
}) => {
  await recordFormFilling(page);
  await flushRecorder(page);

  await page.goto(DASHBOARD, { waitUntil: "domcontentloaded" });
  const sessionLink = page.locator("a.session-id").first();
  await expect(async () => {
    await page.reload({ waitUntil: "domcontentloaded" });
    await expect(sessionLink).toBeVisible({ timeout: 2000 });
  }).toPass({ timeout: 30_000, intervals: [1000, 1000, 2000] });

  await sessionLink.click();
  await expect(page.getByText("Session Details")).toBeVisible();

  // The activity sidebar populates once events load.
  const sidebar = page.locator("#activity-sidebar");
  await expect(sidebar).toBeVisible({ timeout: 20_000 });

  // The form-interaction detail line ("Field N of M") is injected by
  // form-interaction.js into the detail panel of each input significant event.
  // It is the load-bearing artefact of the feature, so assert on it directly.
  // The detail panel lives in the DOM regardless of hover (hover only toggles
  // its visibility), so we assert it is attached and carries the right text.
  // NOTE: under maskAllInputs rrweb may report a text input with an isChecked
  // flag, so the entry label can read "Checkbox …" rather than "Input"; the
  // form-interaction detail is attached to the input significant event either
  // way. We therefore key on the detail line, not the entry label.
  const fieldDetail = page
    .locator(".activity-wrapper .activity-detail .activity-detail-line")
    .filter({ hasText: /Field \d+ of \d+/ });
  await expect(fieldDetail.first()).toBeAttached({ timeout: 20_000 });
  await expect(fieldDetail.first()).toContainText(/Field \d+ of \d+/);
});
