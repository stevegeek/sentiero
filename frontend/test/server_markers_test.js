import { test } from "node:test";
import assert from "node:assert/strict";

import {
  adaptServerMarkers,
  describeEvent,
  getEventDetailLines,
} from "../src/dashboard/events.js";
import { EVENT_CATEGORIES } from "../src/dashboard/utils.js";

test("server categories exist with distinct colors", () => {
  assert.ok(EVENT_CATEGORIES.server_exception, "server_exception category");
  assert.ok(EVENT_CATEGORIES.server_event, "server_event category");
  assert.notEqual(
    EVENT_CATEGORIES.server_exception.color,
    EVENT_CATEGORIES.server_event.color
  );
  // Distinct from the client-side click/error red so server pins stand apart.
  assert.ok(EVENT_CATEGORIES.server_exception.label);
  assert.ok(EVENT_CATEGORIES.server_event.label);
});

test("adaptServerMarkers maps JSON markers into significant-event shape", () => {
  const raw = [
    { offset_ms: 0, kind: "event", label: "checkout", level: "info", href: "/custom-events/e1" },
    { offset_ms: 2000, kind: "exception", label: "RuntimeError: boom", level: "error", href: "/issues/fp1" },
  ];
  const out = adaptServerMarkers(raw);
  assert.equal(out.length, 2);

  const evt = out[0];
  assert.equal(evt.offset, 0);
  assert.equal(evt.category, "server_event");
  assert.equal(evt.label, "checkout");
  assert.equal(evt.href, "/custom-events/e1");

  const exc = out[1];
  assert.equal(exc.offset, 2000);
  assert.equal(exc.category, "server_exception");
  assert.equal(exc.label, "RuntimeError: boom");
  assert.equal(exc.href, "/issues/fp1");
});

test("adaptServerMarkers tolerates empty/invalid input", () => {
  assert.deepEqual(adaptServerMarkers([]), []);
  assert.deepEqual(adaptServerMarkers(null), []);
  assert.deepEqual(adaptServerMarkers(undefined), []);
  assert.deepEqual(adaptServerMarkers("not-array"), []);
});

test("server markers merge into native events sorted by offset", () => {
  const native = [
    { offset: 500, category: "click" },
    { offset: 3000, category: "navigation" },
  ];
  const server = adaptServerMarkers([
    { offset_ms: 0, kind: "event", label: "a", level: "info", href: "/custom-events/e1" },
    { offset_ms: 2000, kind: "exception", label: "boom", level: "error", href: "/issues/fp1" },
  ]);
  const merged = native.concat(server).sort((a, b) => a.offset - b.offset);
  assert.deepEqual(
    merged.map((m) => m.offset),
    [0, 500, 2000, 3000]
  );
  assert.equal(merged[0].category, "server_event");
  assert.equal(merged[2].category, "server_exception");
});

// Regression: the render path (describeEvent + getEventDetailLines) is called in
// a forEach over significant events by the marker/sidebar renderers. Server
// markers have NO underlying rrweb event (no se.event / se.event.data), so the
// render path must not dereference it. Previously getEventDetailLines threw
// "Cannot read properties of undefined (reading 'data')".
test("describeEvent renders server markers from their label without an rrweb event", () => {
  const [evt, exc] = adaptServerMarkers([
    { offset_ms: 0, kind: "event", label: "checkout_started", level: "info", href: "/custom-events/e1" },
    { offset_ms: 2000, kind: "exception", label: "RuntimeError: boom", level: "error", href: "/issues/fp1" },
  ]);
  assert.equal(evt.event, undefined, "server marker has no rrweb event");
  assert.equal(describeEvent(evt), "checkout_started");
  assert.equal(describeEvent(exc), "RuntimeError: boom");
});

test("getEventDetailLines does not throw for server markers and uses their fields", () => {
  const [evt, exc] = adaptServerMarkers([
    { offset_ms: 0, kind: "event", label: "checkout_started", level: "warn", href: "/custom-events/e1" },
    { offset_ms: 2000, kind: "exception", label: "RuntimeError: boom", level: "error", href: "/issues/fp1" },
  ]);
  // Must not throw on the missing rrweb event.
  const evtLines = getEventDetailLines(evt);
  const excLines = getEventDetailLines(exc);
  assert.ok(Array.isArray(evtLines));
  assert.ok(Array.isArray(excLines));
  // Render from the marker's own fields (level + detail link), not se.event.
  assert.ok(evtLines.some((l) => l.includes("warn")), "event level shown");
  assert.ok(excLines.some((l) => l.includes("error")), "exception level shown");
  assert.ok(excLines.some((l) => l.includes("/issues/fp1")), "detail href shown");
});
