import { test } from "node:test";
import assert from "node:assert/strict";

import { Transport } from "../src/transport.js";
import { parseConfig } from "../src/redaction.js";

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

// Regression: rrweb Meta events (type 4) are emitted straight from rrweb's
// `emit` callback, bypassing the addCustomEvent/redactPayload path that
// covers type-5 events. addEvent is the single seam every event passes
// through, so it must redact data.href before the event reaches the buffer.
test("addEvent redacts a meta event's href before buffering", () => {
  const transport = new Transport({ eventsUrl: "https://example.test/events", redactionCfg: parseConfig({}) });
  transport.addEvent({ type: 4, data: { href: "https://app.test/reset?token=s&email=u@e.com", width: 800, height: 600 } });

  assert.equal(transport.buffer.length, 1);
  assert.equal(transport.buffer[0].data.href, "https://app.test/reset");
  assert.equal(transport.buffer[0].data.width, 800);
  assert.equal(transport.buffer[0].data.height, 600);
});

test("addEvent leaves a non-meta, non-custom event untouched", () => {
  const transport = new Transport({ eventsUrl: "https://example.test/events", redactionCfg: parseConfig({}) });
  const event = { type: 3, data: { source: 0, texts: [] } };
  transport.addEvent(event);

  assert.deepEqual(transport.buffer[0], event);
});

test("addEvent respects keepAll url mode for meta href", () => {
  const transport = new Transport({ eventsUrl: "https://example.test/events", redactionCfg: parseConfig({ urlMode: "keepAll" }) });
  transport.addEvent({ type: 4, data: { href: "https://app.test/reset?token=s" } });

  assert.equal(transport.buffer[0].data.href, "https://app.test/reset?token=s");
});
