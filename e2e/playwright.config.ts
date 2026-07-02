import { defineConfig, devices } from "@playwright/test";

/**
 * End-to-end tests for the Sentiero gem.
 *
 * These drive the REAL demo app (demo/app.rb, a Roda todo app) in a real
 * Chromium browser to exercise the shipped recorder bundle, the dashboard
 * replay UI, and (in future) the analytics pages, end to end.
 *
 * The demo server is booted by `./bin/serve` on port 9393 with the File
 * store (Redis intentionally unreachable / unset, so the app falls back to
 * the deterministic file store under demo/tmp/sentiero_sessions).
 */
export default defineConfig({
  testDir: "./tests",
  // File store + a single demo server are shared mutable state, so do not
  // run specs in parallel.
  fullyParallel: false,
  workers: 1,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  timeout: 60_000,
  expect: {
    timeout: 15_000,
  },
  reporter: [["list"]],
  use: {
    baseURL: "http://localhost:9393",
    // The demo's dashboard is HTTP Basic auth (demo / demo). Configuring
    // credentials here means dashboard + API requests authenticate
    // automatically.
    httpCredentials: { username: "demo", password: "demo" },
    trace: "on-first-retry",
  },
  webServer: {
    command: "./bin/serve",
    url: "http://localhost:9393/",
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
    stdout: "pipe",
    stderr: "pipe",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
