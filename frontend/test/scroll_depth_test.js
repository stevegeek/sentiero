import { test } from "node:test";
import assert from "node:assert/strict";

import { maxScrollY, computeScrollDepth } from "../src/dashboard/scroll-depth.js";

// rrweb constants (mirror utils.js)
const TYPE_INCREMENTAL = 3;
const TYPE_META = 4;
const SOURCE_SCROLL = 3;
const SOURCE_MUTATION = 0;

function scroll(y) {
  return {
    type: TYPE_INCREMENTAL,
    data: { source: SOURCE_SCROLL, y },
  };
}

function meta(width, height) {
  return { type: TYPE_META, data: { width, height } };
}

function mutation() {
  return {
    type: TYPE_INCREMENTAL,
    data: { source: SOURCE_MUTATION, adds: [], removes: [] },
  };
}

// ── maxScrollY ───────────────────────────────────────────────────

test("maxScrollY returns 0 for an empty array", () => {
  assert.equal(maxScrollY([]), 0);
});

test("maxScrollY returns 0 for invalid input", () => {
  assert.equal(maxScrollY(null), 0);
  assert.equal(maxScrollY(undefined), 0);
});

test("maxScrollY returns 0 when there are no scroll events", () => {
  assert.equal(maxScrollY([mutation(), meta(1280, 800)]), 0);
});

test("maxScrollY returns the y of a single scroll event", () => {
  assert.equal(maxScrollY([scroll(500)]), 500);
});

test("maxScrollY picks the maximum y even when it is not the last event", () => {
  assert.equal(maxScrollY([scroll(100), scroll(2500), scroll(800)]), 2500);
});

test("maxScrollY ignores non-number y values", () => {
  assert.equal(maxScrollY([{ type: TYPE_INCREMENTAL, data: { source: SOURCE_SCROLL, y: "x" } }]), 0);
});

// ── computeScrollDepth ───────────────────────────────────────────

test("computeScrollDepth returns null for an empty array", () => {
  assert.equal(computeScrollDepth([]), null);
});

test("computeScrollDepth returns null when there are no scroll events", () => {
  assert.equal(computeScrollDepth([mutation(), meta(1280, 800)]), null);
});

test("computeScrollDepth treats a y=0 scroll event the same as no scroll", () => {
  assert.equal(computeScrollDepth([scroll(0), meta(1280, 800)]), null);
});

test("computeScrollDepth without a meta event gives viewports: null", () => {
  assert.deepEqual(computeScrollDepth([scroll(500)]), { y: 500, viewports: null });
});

test("computeScrollDepth with a meta event computes the viewport multiple", () => {
  // (2500 + 800) / 800 = 4.125 → rounded to 1 dp = 4.1
  assert.deepEqual(computeScrollDepth([scroll(2500), meta(1280, 800)]), {
    y: 2500,
    viewports: 4.1,
  });
});

test("computeScrollDepth picks the maximum scroll y across multiple events", () => {
  // max y is 2500 (middle event), (2500 + 1000) / 1000 = 3.5
  const events = [meta(1280, 1000), scroll(800), scroll(2500), scroll(1200)];
  assert.deepEqual(computeScrollDepth(events), { y: 2500, viewports: 3.5 });
});

test("computeScrollDepth never emits a misleading percent field", () => {
  const depth = computeScrollDepth([scroll(2500), meta(1280, 800)]);
  assert.equal("percent" in depth, false);
});
