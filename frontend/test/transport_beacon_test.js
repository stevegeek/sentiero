import { test } from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { gunzipSync } from "fflate";

import { Transport } from "../src/transport.js";
import { parseConfig } from "../src/redaction.js";

const BEACON_MAX_BYTES = 64_000;

function fakeStorage(initial = {}) {
  const jar = new Map(Object.entries(initial));
  return {
    getItem: (k) => (jar.has(k) ? jar.get(k) : null),
    setItem: (k, v) => jar.set(k, String(v)),
    removeItem: (k) => jar.delete(k),
  };
}

// Same env harness as transport_flush_test.js: page origin is https://app.test.
async function withEnv({ sendBeacon, fetch, warn }, fn) {
  const g = globalThis;
  const keys = ["window", "location", "document", "navigator", "localStorage", "sessionStorage", "fetch"];
  const saved = Object.fromEntries(keys.map((k) => [k, Object.getOwnPropertyDescriptor(g, k)]));
  const savedWarn = console.warn;
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
    if (warn) console.warn = warn;
    return await fn();
  } finally {
    console.warn = savedWarn;
    for (const [k, d] of Object.entries(saved)) {
      if (d) Object.defineProperty(g, k, d);
      else delete g[k];
    }
  }
}

async function blobBytes(blob) {
  return new Uint8Array(await blob.arrayBuffer());
}

// The unload beacon must be a CORS-safelisted "simple request" (text/plain,
// no custom headers) so it works against a cross-origin collector, where
// sendBeacon cannot perform the preflight that application/json would need.
test("beacon blob is text/plain, cross-origin and same-origin alike", async () => {
  for (const eventsUrl of ["https://collector.test/events", "https://app.test/events", "/events"]) {
    const sent = [];
    await withEnv({ sendBeacon: (_url, blob) => (sent.push(blob), true) }, async () => {
      const transport = new Transport({ eventsUrl, redactionCfg: parseConfig({}) });
      transport.buffer.push({ id: 1 });
      transport.flushBeacon();
    });
    assert.equal(sent.length, 1, eventsUrl);
    assert.equal(sent[0].type, "text/plain", eventsUrl);
  }
});

// Gzipped so it fits the shared ~64KB keepalive quota; the server detects the
// encoding from the gzip magic bytes, so no Content-Encoding header is needed.
test("beacon body is gzip-compressed and decodes to the events", async () => {
  const sent = [];
  await withEnv({ sendBeacon: (_url, blob) => (sent.push(blob), true) }, async () => {
    const transport = new Transport({ eventsUrl: "https://collector.test/events", redactionCfg: parseConfig({}) });
    transport.buffer.push({ id: 1 }, { id: 2 });
    transport.flushBeacon();
  });

  assert.equal(sent.length, 1);
  const bytes = await blobBytes(sent[0]);
  assert.equal(bytes[0], 0x1f, "gzip magic byte 0");
  assert.equal(bytes[1], 0x8b, "gzip magic byte 1");
  const payload = JSON.parse(new TextDecoder().decode(gunzipSync(bytes)));
  assert.deepEqual(payload.events.map((e) => e.id), [1, 2]);
});

// An oversized batch is split so every chunk fits the quota and ALL events are
// still delivered — splitting, not a keepalive retry, is the answer to a full
// quota (keepalive fetch shares the same budget).
test("an over-quota batch splits into sub-quota beacons carrying every event", async () => {
  const sent = [];
  await withEnv({ sendBeacon: (_url, blob) => (sent.push(blob), true) }, async () => {
    const transport = new Transport({ eventsUrl: "https://collector.test/events", redactionCfg: parseConfig({}) });
    // High-entropy payloads gzip poorly, so this comfortably exceeds 64KB
    // compressed while keeping each single event far under the cap.
    for (let i = 0; i < 400; i++) {
      transport.buffer.push({ id: i, blob: randomBytes(512).toString("hex") });
    }
    transport.flushBeacon();
  });

  assert.ok(sent.length > 1, `expected a split, got ${sent.length} beacon(s)`);

  const ids = [];
  for (const blob of sent) {
    assert.ok(blob.size <= BEACON_MAX_BYTES, `chunk ${blob.size} exceeds cap`);
    const payload = JSON.parse(new TextDecoder().decode(gunzipSync(await blobBytes(blob))));
    ids.push(...payload.events.map((e) => e.id));
  }
  assert.deepEqual(ids.sort((a, b) => a - b), Array.from({ length: 400 }, (_, i) => i));
});

// A rejected beacon is a lost cause on unload (the quota it blew is shared with
// keepalive fetch), so warn rather than silently retrying into the same wall.
test("a rejected beacon warns and does not fall back to fetch", async () => {
  const warnings = [];
  const fetched = [];
  await withEnv({
    sendBeacon: () => false,
    fetch: (url, opts) => (fetched.push({ url, opts }), Promise.resolve({ ok: true })),
    warn: (...args) => warnings.push(args.join(" ")),
  }, async () => {
    const transport = new Transport({ eventsUrl: "https://collector.test/events", redactionCfg: parseConfig({}) });
    transport.buffer.push({ id: 1 });
    transport.flushBeacon();
  });

  assert.equal(fetched.length, 0, "must not use keepalive fetch");
  assert.ok(warnings.some((w) => w.includes("Sentiero")), "must warn about the loss");
});
