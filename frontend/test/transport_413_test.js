import { test } from "node:test";
import assert from "node:assert/strict";
import { gunzipSync } from "fflate";

import { Transport } from "../src/transport.js";
import { parseConfig } from "../src/redaction.js";

function fakeStorage(initial = {}) {
  const jar = new Map(Object.entries(initial));
  return {
    getItem: (k) => (jar.has(k) ? jar.get(k) : null),
    setItem: (k, v) => jar.set(k, String(v)),
    removeItem: (k) => jar.delete(k),
  };
}

// Mirrors transport_flush_test.js: browser globals installed for the async fn.
async function withEnv({ sendBeacon, fetch }, fn) {
  const g = globalThis;
  const keys = ["window", "location", "document", "navigator", "localStorage", "sessionStorage", "fetch"];
  const saved = Object.fromEntries(keys.map((k) => [k, Object.getOwnPropertyDescriptor(g, k)]));
  const href = "https://app.test/home";
  const locationObj = { href, origin: new URL(href).origin };
  const windowObj = { location: locationObj, innerWidth: 1280, innerHeight: 720 };
  try {
    Object.defineProperty(g, "window", { value: windowObj, configurable: true, writable: true });
    Object.defineProperty(g, "location", { value: locationObj, configurable: true });
    Object.defineProperty(g, "document", { value: { referrer: "" }, configurable: true });
    Object.defineProperty(g, "navigator", { value: { userAgent: "test-ua", sendBeacon }, configurable: true });
    Object.defineProperty(g, "localStorage", { value: fakeStorage(), configurable: true });
    Object.defineProperty(g, "sessionStorage", { value: fakeStorage(), configurable: true });
    if (fetch) Object.defineProperty(g, "fetch", { value: fetch, configurable: true, writable: true });
    return await fn();
  } finally {
    for (const [k, d] of Object.entries(saved)) {
      if (d) Object.defineProperty(g, k, d);
      else delete g[k];
    }
  }
}

const tick = () => new Promise((r) => setTimeout(r, 0));

function decodeEvents(body) {
  return JSON.parse(new TextDecoder().decode(gunzipSync(body))).events;
}

test("413 halves the batch until it fits instead of retrying it verbatim", async () => {
  const delivered = [];
  const fetchMock = (_url, opts) => {
    const events = decodeEvents(opts.body);
    if (events.length > 2) return Promise.resolve({ ok: false, status: 413 });
    delivered.push(events.map((e) => e.id));
    return Promise.resolve({ ok: true });
  };

  await withEnv({ sendBeacon: () => true, fetch: fetchMock }, async () => {
    const transport = new Transport({ eventsUrl: "https://events.test/e", redactionCfg: parseConfig({}) });
    for (let i = 1; i <= 8; i++) transport.buffer.push({ id: i });

    transport.flush();
    for (let i = 0; i < 20; i++) await tick();

    assert.deepEqual(delivered.flat(), [1, 2, 3, 4, 5, 6, 7, 8]);
    assert.equal(transport.buffer.length, 0);
    assert.equal(transport._retryCount, 0);
  });
});

test("a single event still over the cap is dropped with a distinct warning", async () => {
  const delivered = [];
  const fetchMock = (_url, opts) => {
    const events = decodeEvents(opts.body);
    if (events.some((e) => e.id === "big")) return Promise.resolve({ ok: false, status: 413 });
    delivered.push(events.map((e) => e.id));
    return Promise.resolve({ ok: true });
  };

  const warnings = [];
  const originalWarn = console.warn;
  console.warn = (...args) => warnings.push(args.join(" "));
  try {
    await withEnv({ sendBeacon: () => true, fetch: fetchMock }, async () => {
      const transport = new Transport({ eventsUrl: "https://events.test/e", redactionCfg: parseConfig({}) });
      transport.buffer.push({ id: "big" });

      transport.flush();
      for (let i = 0; i < 10; i++) await tick();

      assert.equal(transport.buffer.length, 0);
      assert.equal(transport._retryCount, 0);

      transport.buffer.push({ id: "after" });
      transport.flush();
      for (let i = 0; i < 10; i++) await tick();

      assert.deepEqual(delivered.flat(), ["after"]);
    });
  } finally {
    console.warn = originalWarn;
  }

  assert.ok(
    warnings.some((w) => w.includes("body cap")),
    `expected a body-cap warning, got: ${JSON.stringify(warnings)}`
  );
});

test("the learned batch cap applies to later flushes", async () => {
  const batchSizes = [];
  let rejectLarge = true;
  const fetchMock = (_url, opts) => {
    const events = decodeEvents(opts.body);
    if (rejectLarge && events.length > 2) return Promise.resolve({ ok: false, status: 413 });
    batchSizes.push(events.length);
    return Promise.resolve({ ok: true });
  };

  await withEnv({ sendBeacon: () => true, fetch: fetchMock }, async () => {
    const transport = new Transport({ eventsUrl: "https://events.test/e", redactionCfg: parseConfig({}) });
    for (let i = 1; i <= 8; i++) transport.buffer.push({ id: i });
    transport.flush();
    for (let i = 0; i < 20; i++) await tick();

    rejectLarge = false;
    for (let i = 9; i <= 14; i++) transport.buffer.push({ id: i });
    transport.flush();
    for (let i = 0; i < 20; i++) await tick();

    assert.ok(
      batchSizes.every((size) => size <= 2),
      `expected all batches capped at 2, got: ${JSON.stringify(batchSizes)}`
    );
    assert.equal(transport.buffer.length, 0);
  });
});
