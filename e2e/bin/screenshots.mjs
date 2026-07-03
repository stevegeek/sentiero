// Regenerates the three README screenshots in demo/ against a running demo.
//
//   cd demo && env -u REDIS_URL PORT=9295 bundle exec puma -p 9295   # clean store first!
//   cd e2e && node bin/screenshots.mjs
//
// Wipe demo/tmp/sentiero_sessions before booting so the session list shows
// only the three sessions this script records. Sizes match the previous
// captures so the README image table keeps its layout.
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const BASE = process.env.BASE_URL ?? "http://127.0.0.1:9295";
const OUT = fileURLToPath(new URL("../../demo", import.meta.url));
const CONSENT = {
  name: "sentiero_demo_consent",
  value: "granted",
  url: BASE,
};

const browser = await chromium.launch();

async function newPage(viewport, { consent = true } = {}) {
  const ctx = await browser.newContext({
    viewport,
    httpCredentials: { username: "demo", password: "demo" },
  });
  if (consent) await ctx.addCookies([CONSENT]);
  return ctx;
}

// Flush the recorder the same way the e2e fixtures do: simulate tab-hidden
// and wait for the resulting POST /sentiero/events.
async function flush(page) {
  const done = page
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
  await done;
}

// Flush before every navigating click: the recorder's own pagehide beacon is
// aborted by Playwright-controlled navigations, so buffered events would be
// lost and the recorded sessions would look empty.
async function addTodo(page, text) {
  await page.locator('input[name="text"]').fill(text);
  await flush(page);
  await page.getByRole("button", { name: "Add" }).click();
  await page.getByText(text).waitFor();
}

// --- Session 1: the front page, todos added; this is also the app screenshot.
{
  const ctx = await newPage({ width: 1020, height: 1126 });
  const page = await ctx.newPage();
  await page.goto(BASE + "/", { waitUntil: "networkidle" });
  await addTodo(page, "Pack the tent");
  await page.waitForTimeout(1500);
  await addTodo(page, "Book the campsite");
  await page.waitForTimeout(1500);
  await addTodo(page, "Print the trail map");
  await page.waitForTimeout(1500);
  // Mark the first-added todo done (it renders last in the reversed list).
  await flush(page);
  await page
    .locator("li")
    .filter({ hasText: "Pack the tent" })
    .getByRole("button", { name: "Done" })
    .click();
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${OUT}/screenshot-demo-app.png` });
  await flush(page);
  await ctx.close();
}

// --- Session 2: landing page with scrolling, so the list shows variety.
{
  const ctx = await newPage({ width: 1280, height: 800 });
  const page = await ctx.newPage();
  await page.goto(BASE + "/landing", { waitUntil: "networkidle" });
  await page.mouse.wheel(0, 2400);
  await page.waitForTimeout(500);
  await page.mouse.wheel(0, 2400);
  await page.waitForTimeout(500);
  await flush(page);
  await ctx.close();
}

// --- Session 3: signup flow into the app.
{
  const ctx = await newPage({ width: 1280, height: 800 });
  const page = await ctx.newPage();
  await page.goto(BASE + "/signup", { waitUntil: "networkidle" });
  await page.locator('input[name="name"]').fill("Sam Hiker");
  await page.locator('input[name="email"]').fill("sam@example.com");
  await flush(page);
  await page.getByRole("button", { name: "Create account" }).click();
  await page.waitForURL(BASE + "/");
  await addTodo(page, "Charge the head torch");
  await flush(page);
  await ctx.close();
}

// --- Dashboard: session list.
{
  const ctx = await newPage({ width: 1558, height: 588 });
  const page = await ctx.newPage();
  await page.goto(BASE + "/sentiero/dashboard/", {
    waitUntil: "networkidle",
  });
  await page.locator("a.session-id").first().waitFor();
  await page.screenshot({ path: `${OUT}/screenshot-index.png` });

  // --- Dashboard: replay page of the todo session (the biggest one).
  await page.setViewportSize({ width: 1548, height: 1378 });
  await page.locator("a.session-id").last().click();
  await page.waitForLoadState("networkidle");
  // Let the rrweb player mount and render the first frame.
  await page.waitForTimeout(3000);
  await page.screenshot({ path: `${OUT}/screenshot-recording.png` });
  await ctx.close();
}

await browser.close();
console.log("screenshots written to " + OUT);
