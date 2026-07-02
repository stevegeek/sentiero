import { test } from "node:test";
import assert from "node:assert/strict";

import { Transport } from "../src/transport.js";

// The Transport constructor reads session/window ids from web storage, absent
// under node, so provide a minimal in-memory stand-in.
function fakeStorage() {
  const map = new Map();
  return {
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, String(v)),
    removeItem: (k) => map.delete(k),
  };
}
globalThis.localStorage = fakeStorage();
globalThis.sessionStorage = fakeStorage();

function makeTransport() {
  return new Transport({ eventsUrl: "https://example.test/events" });
}

test("discard drops buffered events without flushing", () => {
  let fetchCalls = 0;
  const originalFetch = globalThis.fetch;
  globalThis.fetch = () => {
    fetchCalls++;
    return Promise.resolve({ ok: true });
  };
  try {
    const transport = makeTransport();
    transport.addEvent({ type: 1 });
    transport.addEvent({ type: 2 });
    assert.equal(transport.buffer.length, 2);

    transport.discard();

    assert.equal(transport.buffer.length, 0);
    transport.flush();
    transport.flushBeacon();
    assert.equal(fetchCalls, 0, "no events should be sent after discard");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("discard stops the flush interval", () => {
  const transport = makeTransport();
  transport.start();
  assert.notEqual(transport._intervalId, null);
  transport.discard();
  assert.equal(transport._intervalId, null);
});

test("discard is idempotent and safe before start", () => {
  const transport = makeTransport();
  assert.doesNotThrow(() => {
    transport.discard();
    transport.discard();
  });
});

test("addEvent after discard never triggers a send", () => {
  let fetchCalls = 0;
  const originalFetch = globalThis.fetch;
  globalThis.fetch = () => {
    fetchCalls++;
    return Promise.resolve({ ok: true });
  };
  try {
    const transport = makeTransport();
    transport.discard();
    // Push past the flush threshold; the _stopped guard must keep flush a no-op.
    for (let i = 0; i < transport.flushEventThreshold + 1; i++) {
      transport.addEvent({ type: i });
    }
    assert.equal(fetchCalls, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
