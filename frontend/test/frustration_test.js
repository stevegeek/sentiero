import { test } from "node:test";
import assert from "node:assert/strict";

import {
  detectRageClicks,
  detectDeadClicks,
  detectFrustrationEvents,
} from "../src/dashboard/frustration.js";

// rrweb constants (mirror utils.js)
const TYPE_INCREMENTAL = 3;
const SOURCE_MUTATION = 0;
const SOURCE_MOUSE_INTERACTION = 2;
const SOURCE_INPUT = 5;
const MOUSE_CLICK = 2;

// Build a click event at (x, y) and a timestamp.
function click(ts, x, y) {
  return {
    type: TYPE_INCREMENTAL,
    timestamp: ts,
    data: { source: SOURCE_MOUSE_INTERACTION, type: MOUSE_CLICK, x, y },
  };
}

function mutation(ts) {
  return {
    type: TYPE_INCREMENTAL,
    timestamp: ts,
    data: { source: SOURCE_MUTATION, adds: [], removes: [], attributes: [], texts: [] },
  };
}

function input(ts) {
  return {
    type: TYPE_INCREMENTAL,
    timestamp: ts,
    data: { source: SOURCE_INPUT, text: "x" },
  };
}

// ── detectRageClicks ─────────────────────────────────────────────

test("detectRageClicks returns empty when there are no clicks", () => {
  assert.deepEqual(detectRageClicks([mutation(0), input(10)]), []);
});

test("detectRageClicks returns empty for an empty/invalid input", () => {
  assert.deepEqual(detectRageClicks([]), []);
  assert.deepEqual(detectRageClicks(null), []);
});

test("detectRageClicks flags 3 clicks within 500ms at the same coords", () => {
  const events = [click(0, 100, 100), click(100, 102, 99), click(200, 98, 101)];
  const out = detectRageClicks(events);
  assert.equal(out.length, 1);
  assert.equal(out[0].subtype, "rage_click");
  assert.equal(out[0].count, 3);
  assert.equal(out[0].timestamp, 0);
});

test("detectRageClicks does not flag exactly 2 clicks", () => {
  const events = [click(0, 100, 100), click(100, 100, 100)];
  assert.deepEqual(detectRageClicks(events), []);
});

test("detectRageClicks ignores clicks more than 500ms apart", () => {
  // gaps of 600ms between each → never 3 within a 500ms window
  const events = [click(0, 100, 100), click(600, 100, 100), click(1200, 100, 100)];
  assert.deepEqual(detectRageClicks(events), []);
});

test("detectRageClicks ignores clicks more than 10px apart", () => {
  const events = [click(0, 100, 100), click(100, 200, 100), click(200, 300, 100)];
  assert.deepEqual(detectRageClicks(events), []);
});

test("detectRageClicks counts a long burst as a single rage cluster", () => {
  const events = [
    click(0, 50, 50),
    click(100, 51, 50),
    click(200, 50, 51),
    click(300, 52, 50),
  ];
  const out = detectRageClicks(events);
  assert.equal(out.length, 1);
  assert.equal(out[0].count, 4);
});

test("detectRageClicks does not flag a burst that spans more than 500ms", () => {
  // ~499ms per-pair gaps stay under the per-pair limit, but the cluster span
  // (998ms) exceeds the 500ms window — must not be reported as a rage cluster.
  const events = [click(0, 10, 10), click(499, 10, 10), click(998, 10, 10)];
  assert.deepEqual(detectRageClicks(events), []);
});

test("detectRageClicks works with non-click events interleaved", () => {
  const events = [
    click(0, 10, 10),
    mutation(50),
    click(100, 11, 10),
    input(150),
    click(200, 10, 11),
  ];
  const out = detectRageClicks(events);
  assert.equal(out.length, 1);
  assert.equal(out[0].count, 3);
});

// ── detectDeadClicks ─────────────────────────────────────────────

test("detectDeadClicks returns empty when there are no clicks", () => {
  assert.deepEqual(detectDeadClicks([mutation(0), input(10)]), []);
});

test("detectDeadClicks flags a click with no mutation within 500ms", () => {
  const events = [click(0, 5, 5), mutation(800)];
  const out = detectDeadClicks(events);
  assert.equal(out.length, 1);
  assert.equal(out[0].subtype, "dead_click");
  assert.equal(out[0].timestamp, 0);
});

test("detectDeadClicks does not flag a click followed by a mutation within 500ms", () => {
  const events = [click(0, 5, 5), mutation(300)];
  assert.deepEqual(detectDeadClicks(events), []);
});

test("detectDeadClicks treats a mutation at exactly 500ms as responsive", () => {
  const events = [click(0, 5, 5), mutation(500)];
  assert.deepEqual(detectDeadClicks(events), []);
});

test("detectDeadClicks does not flag a click followed by input within 500ms", () => {
  const events = [click(0, 5, 5), input(100)];
  assert.deepEqual(detectDeadClicks(events), []);
});

test("detectDeadClicks flags the last click when nothing follows", () => {
  const events = [mutation(0), click(1000, 5, 5)];
  const out = detectDeadClicks(events);
  assert.equal(out.length, 1);
  assert.equal(out[0].subtype, "dead_click");
});

// ── detectFrustrationEvents ──────────────────────────────────────

test("detectFrustrationEvents returns sidebar-shaped, offset-sorted entries", () => {
  const events = [
    mutation(0),
    // rage burst at ts 1000..1200
    click(1000, 100, 100),
    click(1100, 101, 100),
    click(1200, 100, 101),
    mutation(1250),
    // dead click at ts 5000, no mutation within 500ms
    click(5000, 300, 300),
    mutation(5800),
  ];
  const out = detectFrustrationEvents(events);
  assert.equal(out.length, 2);
  out.forEach((e) => {
    assert.equal(e.category, "frustration");
    assert.equal(typeof e.offset, "number");
    assert.ok(e.event);
  });
  // offsets are relative to the first event timestamp (0) and sorted ascending
  assert.equal(out[0].subtype, "rage_click");
  assert.equal(out[0].offset, 1000);
  assert.equal(out[1].subtype, "dead_click");
  assert.equal(out[1].offset, 5000);
});

test("detectFrustrationEvents does not double-report rage-cluster clicks as dead", () => {
  // 3 rage clicks with no following mutation: should be one rage entry, not
  // three dead-click entries on top.
  const events = [click(0, 10, 10), click(100, 10, 10), click(200, 10, 10)];
  const out = detectFrustrationEvents(events);
  const rage = out.filter((e) => e.subtype === "rage_click");
  const dead = out.filter((e) => e.subtype === "dead_click");
  assert.equal(rage.length, 1);
  assert.equal(dead.length, 0);
});
