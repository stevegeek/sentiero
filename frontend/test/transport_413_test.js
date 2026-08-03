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
      assert.ok(transport._retryCount >= 1, "drop escalates the failure counters");

      transport._retryCount = 0;
      transport._lastFailureTime = null;
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

test("the learned cap keeps deliveries small while the server keeps rejecting", async () => {
  const batchSizes = [];
  const fetchMock = (_url, opts) => {
    const events = decodeEvents(opts.body);
    if (events.length > 2) return Promise.resolve({ ok: false, status: 413 });
    batchSizes.push(events.length);
    return Promise.resolve({ ok: true });
  };

  await withEnv({ sendBeacon: () => true, fetch: fetchMock }, async () => {
    const transport = new Transport({ eventsUrl: "https://events.test/e", redactionCfg: parseConfig({}) });
    for (let i = 1; i <= 8; i++) transport.buffer.push({ id: i });
    transport.flush();
    for (let i = 0; i < 30; i++) await tick();

    assert.equal(batchSizes.reduce((a, b) => a + b, 0), 8, "everything is delivered");
    assert.ok(
      batchSizes.every((size) => size <= 2),
      `expected all delivered batches within the server's limit, got: ${JSON.stringify(batchSizes)}`
    );
    assert.equal(transport.buffer.length, 0);
  });
});

test("a persistent 413 is throttled by backoff instead of draining at network speed", async () => {
  let fetchCalls = 0;
  const fetchMock = () => {
    fetchCalls++;
    return Promise.resolve({ ok: false, status: 413 });
  };

  const originalWarn = console.warn;
  console.warn = () => {};
  try {
    await withEnv({ sendBeacon: () => true, fetch: fetchMock }, async () => {
      const transport = new Transport({ eventsUrl: "https://events.test/e", redactionCfg: parseConfig({}) });
      for (let i = 1; i <= 4; i++) transport.buffer.push({ id: i });

      transport.flush();
      for (let i = 0; i < 20; i++) await tick();

      // Cascade 4 -> 2 -> 1(drop) = 3 requests; the drop escalates the
      // failure counters so further flushes wait out the backoff window.
      assert.equal(fetchCalls, 3);
      assert.ok(transport._retryCount >= 1);
      assert.equal(transport.buffer.length, 3);

      transport.flush();
      for (let i = 0; i < 5; i++) await tick();
      assert.equal(fetchCalls, 3, "flush during backoff must not hit the network");
    });
  } finally {
    console.warn = originalWarn;
  }
});

test("metadata survives a dropped oversized event", async () => {
  const bodies = [];
  const fetchMock = (_url, opts) => {
    const body = JSON.parse(new TextDecoder().decode(gunzipSync(opts.body)));
    if (body.events.some((e) => e.id === "big")) return Promise.resolve({ ok: false, status: 413 });
    bodies.push(body);
    return Promise.resolve({ ok: true });
  };

  const originalWarn = console.warn;
  console.warn = () => {};
  try {
    await withEnv({ sendBeacon: () => true, fetch: fetchMock }, async () => {
      const transport = new Transport({
        eventsUrl: "https://events.test/e",
        captureMetadata: true,
        redactionCfg: parseConfig({}),
      });
      transport.setMetadata({ plan: "pro" });
      transport.buffer.push({ id: "big" });

      transport.flush();
      for (let i = 0; i < 10; i++) await tick();

      assert.equal(transport._metadataSent, false, "metadata flag must reset when its carrier is dropped");

      transport._retryCount = 0;
      transport._lastFailureTime = null;
      transport.buffer.push({ id: "after" });
      transport.flush();
      for (let i = 0; i < 10; i++) await tick();

      assert.equal(bodies.length, 1);
      assert.equal(bodies[0].metadata?.plan, "pro");
    });
  } finally {
    console.warn = originalWarn;
  }
});

test("the batch cap regrows on success and clears at maxBufferSize", async () => {
  let rejectLarge = true;
  const fetchMock = (_url, opts) => {
    const events = decodeEvents(opts.body);
    if (rejectLarge && events.length > 2) return Promise.resolve({ ok: false, status: 413 });
    return Promise.resolve({ ok: true });
  };

  await withEnv({ sendBeacon: () => true, fetch: fetchMock }, async () => {
    const transport = new Transport({ eventsUrl: "https://events.test/e", maxBufferSize: 8, redactionCfg: parseConfig({}) });
    for (let i = 1; i <= 4; i++) transport.buffer.push({ id: i });
    transport.flush();
    for (let i = 0; i < 20; i++) await tick();
    // 413(4) halves to 2, then the two successful deliveries double it: 4, 8.
    assert.equal(transport._batchCap, 8);

    rejectLarge = false;
    for (let i = 5; i <= 8; i++) transport.buffer.push({ id: i });
    transport.flush();
    for (let i = 0; i < 20; i++) await tick();
    assert.equal(transport._batchCap, null, "cap should clear once it reaches maxBufferSize");
    assert.equal(transport.buffer.length, 0);
  });
});

test("a 413 resend while the page is hidden goes through the beacon lane", async () => {
  let fetchCalls = 0;
  const beaconBodies = [];
  const fetchMock = () => {
    fetchCalls++;
    return Promise.resolve({ ok: false, status: 413 });
  };
  const sendBeacon = (_url, blob) => {
    beaconBodies.push(blob);
    return true;
  };

  await withEnv({ sendBeacon, fetch: fetchMock }, async () => {
    document.visibilityState = "hidden";
    const transport = new Transport({ eventsUrl: "https://events.test/e", redactionCfg: parseConfig({}) });
    for (let i = 1; i <= 8; i++) transport.buffer.push({ id: i });

    transport.flush();
    for (let i = 0; i < 10; i++) await tick();

    assert.equal(fetchCalls, 1, "no follow-up fetch once the page is hidden");
    assert.ok(beaconBodies.length >= 1, "requeued events must leave via sendBeacon");
    assert.equal(transport.buffer.length, 0);
  });
});
