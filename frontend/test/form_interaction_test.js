import { test } from "node:test";
import assert from "node:assert/strict";

import {
  analyzeFormInteractions,
  buildFormContext,
  getFormInteractionDetail,
} from "../src/dashboard/form-interaction.js";

// rrweb constants (mirror utils.js)
const TYPE_INCREMENTAL = 3;
const TYPE_META = 4;
const SOURCE_MOUSE_INTERACTION = 2;
const SOURCE_INPUT = 5;
const MOUSE_CLICK = 2;

// Build an rrweb input event for a given node id at a timestamp.
function input(ts, id, opts = {}) {
  const data = { source: SOURCE_INPUT, id };
  if ("text" in opts) data.text = opts.text;
  if ("isChecked" in opts) data.isChecked = opts.isChecked;
  return { type: TYPE_INCREMENTAL, timestamp: ts, data };
}

function click(ts, x, y) {
  return {
    type: TYPE_INCREMENTAL,
    timestamp: ts,
    data: { source: SOURCE_MOUSE_INTERACTION, type: MOUSE_CLICK, x, y },
  };
}

function meta(ts) {
  return { type: TYPE_META, timestamp: ts, data: { href: "http://x/", width: 1, height: 1 } };
}

// ── analyzeFormInteractions ──────────────────────────────────────

test("analyzeFormInteractions returns empty for invalid/empty input", () => {
  assert.deepEqual(analyzeFormInteractions(null), []);
  assert.deepEqual(analyzeFormInteractions([]), []);
  assert.deepEqual(analyzeFormInteractions([click(0, 1, 1), meta(0)]), []);
});

test("analyzeFormInteractions groups events by node id in first-touch order", () => {
  const events = [
    input(0, 100, { text: "a" }),
    input(1000, 101, { text: "b" }),
    input(2000, 100, { text: "ab" }),
  ];
  const out = analyzeFormInteractions(events);
  assert.equal(out.length, 2);
  // ordered by first interaction time
  assert.equal(out[0].nodeId, 100);
  assert.equal(out[1].nodeId, 101);
  assert.equal(out[0].order, 1);
  assert.equal(out[1].order, 2);
});

test("analyzeFormInteractions counts re-fills per field", () => {
  const events = [
    input(0, 100, { text: "a" }),
    input(500, 100, { text: "ab" }),
    input(900, 100, { text: "abc" }),
    input(1500, 101, { text: "x" }),
  ];
  const out = analyzeFormInteractions(events);
  const f100 = out.find((f) => f.nodeId === 100);
  const f101 = out.find((f) => f.nodeId === 101);
  assert.equal(f100.fillCount, 3);
  assert.equal(f101.fillCount, 1);
  assert.equal(f100.firstTimestamp, 0);
  assert.equal(f100.lastTimestamp, 900);
  assert.equal(f100.isToggle, false);
});

test("analyzeFormInteractions flags checkbox/radio fields as toggles", () => {
  const events = [
    input(0, 50, { isChecked: true }),
    input(200, 50, { isChecked: false }),
  ];
  const out = analyzeFormInteractions(events);
  assert.equal(out.length, 1);
  assert.equal(out[0].isToggle, true);
  assert.equal(out[0].fillCount, 2);
});

// ── buildFormContext ─────────────────────────────────────────────

test("buildFormContext indexes fields by node id and exposes ordered sequence", () => {
  const events = [
    input(0, 100, { text: "a" }),
    input(1000, 101, { text: "b" }),
  ];
  const ctx = buildFormContext(events);
  assert.equal(ctx.totalFields, 2);
  assert.ok(ctx.byNodeId[100]);
  assert.ok(ctx.byNodeId[101]);
  assert.equal(ctx.byNodeId[100].order, 1);
  assert.equal(ctx.byNodeId[101].order, 2);
  assert.deepEqual(ctx.sequence, [ctx.byNodeId[100].label, ctx.byNodeId[101].label]);
});

test("buildFormContext on empty events gives an empty, safe context", () => {
  const ctx = buildFormContext([]);
  assert.equal(ctx.totalFields, 0);
  assert.deepEqual(ctx.sequence, []);
  assert.deepEqual(ctx.byNodeId, {});
});

// ── getFormInteractionDetail ─────────────────────────────────────

test("getFormInteractionDetail returns [] for non-input events", () => {
  const ctx = buildFormContext([input(0, 100, { text: "a" })]);
  const se = { category: "click", event: click(0, 1, 1) };
  assert.deepEqual(getFormInteractionDetail(se, ctx), []);
});

test("getFormInteractionDetail returns [] when context is missing", () => {
  const se = { category: "input", event: input(0, 100, { text: "a" }) };
  assert.deepEqual(getFormInteractionDetail(se, null), []);
  assert.deepEqual(getFormInteractionDetail(se, undefined), []);
});

test("getFormInteractionDetail surfaces field label and order", () => {
  const events = [
    input(0, 100, { text: "a" }),
    input(1000, 101, { text: "b" }),
  ];
  const ctx = buildFormContext(events);
  const se = { category: "input", event: events[0] };
  const lines = getFormInteractionDetail(se, ctx);
  const joined = lines.join("\n");
  assert.match(joined, /Field 1 of 2/);
});

test("getFormInteractionDetail reports re-fill count when re-filled", () => {
  const events = [
    input(0, 100, { text: "a" }),
    input(400, 100, { text: "ab" }),
    input(800, 100, { text: "abc" }),
  ];
  const ctx = buildFormContext(events);
  const se = { category: "input", event: events[2] };
  const joined = getFormInteractionDetail(se, ctx).join("\n");
  assert.match(joined, /Re-filled: 3 times/);
});

test("getFormInteractionDetail reports toggle count for checkboxes", () => {
  const events = [
    input(0, 50, { isChecked: true }),
    input(200, 50, { isChecked: false }),
  ];
  const ctx = buildFormContext(events);
  const se = { category: "input", event: events[1] };
  const joined = getFormInteractionDetail(se, ctx).join("\n");
  assert.match(joined, /Toggled: 2 times/);
  assert.doesNotMatch(joined, /Re-filled/);
});

test("getFormInteractionDetail reports active time-between to next field within idle window", () => {
  const events = [
    input(0, 100, { text: "a" }),
    input(2300, 101, { text: "b" }),
  ];
  const ctx = buildFormContext(events);
  const se = { category: "input", event: events[0] };
  const joined = getFormInteractionDetail(se, ctx).join("\n");
  // 2300ms gap to next field; shown rounded
  assert.match(joined, /Time to next field/);
});

test("getFormInteractionDetail omits time-between when the gap is an idle gap", () => {
  const events = [
    input(0, 100, { text: "a" }),
    input(60000, 101, { text: "b" }), // 60s idle gap
  ];
  const ctx = buildFormContext(events);
  const se = { category: "input", event: events[0] };
  const joined = getFormInteractionDetail(se, ctx).join("\n");
  assert.doesNotMatch(joined, /Time to next field/);
});

test("getFormInteractionDetail never leaks raw node ids or values", () => {
  const events = [input(0, 987654, { text: "secret-value" })];
  const ctx = buildFormContext(events);
  const se = { category: "input", event: events[0] };
  const joined = getFormInteractionDetail(se, ctx).join("\n");
  assert.doesNotMatch(joined, /987654/);
  assert.doesNotMatch(joined, /secret-value/);
});
