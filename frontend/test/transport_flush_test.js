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

// Sets up browser globals (incl. navigator.sendBeacon / fetch) for the async fn,
// restoring after it settles. Awaits fn so the globals stay in place across its
// awaits (a sync finally would restore them before the body resumes).
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

test("custom metadata is sent once, not re-attached to every flush", async () => {
  const bodies = [];
  const fetchMock = (_url, opts) => {
    bodies.push(JSON.parse(new TextDecoder().decode(gunzipSync(opts.body))));
    return Promise.resolve({ ok: true });
  };
  await withEnv({ sendBeacon: () => true, fetch: fetchMock }, async () => {
    const transport = new Transport({ eventsUrl: "https://events.test/e", redactionCfg: parseConfig({}) });
    transport.setMetadata({ plan: "pro" });

    const tick = () => new Promise((r) => setTimeout(r, 0));

    transport.buffer.push({ id: 1 });
    transport.flush();
    await tick();

    transport.buffer.push({ id: 2 });
    transport.flush();
    await tick();

    assert.equal(bodies.length, 2);
    assert.deepEqual(bodies[0].metadata, { plan: "pro" }, "first flush carries the custom metadata");
    assert.equal(bodies[1].metadata, undefined, "second flush does not re-send it");
  });
});
