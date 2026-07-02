import { test } from "node:test";
import assert from "node:assert/strict";

import { parseEventsJSON, validateEvents } from "../src/analytics/import.js";

// ── parseEventsJSON ──────────────────────────────────────────────

test("parseEventsJSON parses a valid events array", () => {
  const result = parseEventsJSON('[{"type":4,"timestamp":1}]');
  assert.equal(result.ok, true);
  assert.deepEqual(result.events, [{ type: 4, timestamp: 1 }]);
});

test("parseEventsJSON accepts an empty array", () => {
  const result = parseEventsJSON("[]");
  assert.equal(result.ok, true);
  assert.deepEqual(result.events, []);
});

test("parseEventsJSON ignores surrounding whitespace", () => {
  const result = parseEventsJSON("  [{}]  ");
  assert.equal(result.ok, true);
});

test("parseEventsJSON rejects empty input", () => {
  const result = parseEventsJSON("   ");
  assert.equal(result.ok, false);
  assert.match(result.error, /paste|file|empty/i);
});

test("parseEventsJSON reports a friendly error for malformed JSON", () => {
  const result = parseEventsJSON("{not json");
  assert.equal(result.ok, false);
  assert.match(result.error, /valid JSON/i);
});

test("parseEventsJSON does not leak the raw parser exception", () => {
  const result = parseEventsJSON("{not json");
  assert.equal(result.ok, false);
  assert.doesNotMatch(result.error, /SyntaxError|Unexpected token|position/i);
});

test("parseEventsJSON rejects a JSON object (not an array)", () => {
  const result = parseEventsJSON('{"type":4}');
  assert.equal(result.ok, false);
  assert.match(result.error, /array/i);
});

test("parseEventsJSON rejects a JSON scalar", () => {
  const result = parseEventsJSON("42");
  assert.equal(result.ok, false);
  assert.match(result.error, /array/i);
});

// ── validateEvents ───────────────────────────────────────────────

test("validateEvents accepts an array of event-like objects", () => {
  const result = validateEvents([
    { type: 2, timestamp: 1 },
    { type: 3, timestamp: 2, data: {} },
  ]);
  assert.equal(result.ok, true);
});

test("validateEvents rejects a non-array", () => {
  assert.equal(validateEvents({ type: 4 }).ok, false);
  assert.equal(validateEvents(null).ok, false);
});

test("validateEvents rejects an empty array", () => {
  const result = validateEvents([]);
  assert.equal(result.ok, false);
  assert.match(result.error, /no events|empty/i);
});

test("validateEvents needs at least two events to build a timeline", () => {
  const result = validateEvents([{ type: 4, timestamp: 1 }]);
  assert.equal(result.ok, false);
  assert.match(result.error, /two|2/i);
});

test("validateEvents rejects entries missing a numeric type", () => {
  const result = validateEvents([
    { timestamp: 1 },
    { type: 3, timestamp: 2 },
  ]);
  assert.equal(result.ok, false);
  assert.match(result.error, /type/i);
});

test("validateEvents rejects entries missing a numeric timestamp", () => {
  const result = validateEvents([
    { type: 2, timestamp: 1 },
    { type: 3 },
  ]);
  assert.equal(result.ok, false);
  assert.match(result.error, /timestamp/i);
});

test("validateEvents rejects null entries", () => {
  const result = validateEvents([{ type: 2, timestamp: 1 }, null]);
  assert.equal(result.ok, false);
});
