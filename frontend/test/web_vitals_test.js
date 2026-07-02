import { test } from "node:test";
import assert from "node:assert/strict";

import {
  extractWebVitals,
  formatVitalValue,
} from "../src/dashboard/web_vitals.js";

const TYPE_CUSTOM = 5;

// Build a "__perf" custom event carrying a single Web Vital metric.
function perf(metric, value, rating) {
  return {
    type: TYPE_CUSTOM,
    data: { tag: "__perf", payload: { metric, value, rating } },
  };
}

// ── extractWebVitals ─────────────────────────────────────────────

test("extractWebVitals returns empty for invalid input", () => {
  // The accumulator is a null-prototype object (prototype-pollution guard),
  // so compare key sets rather than against a plain {}.
  assert.deepEqual(Object.keys(extractWebVitals(null)), []);
  assert.deepEqual(Object.keys(extractWebVitals([])), []);
});

test("extractWebVitals collects metrics keyed by name", () => {
  const events = [
    perf("LCP", 1200, "good"),
    perf("CLS", 0.05, "good"),
    perf("INP", 250, "needs-improvement"),
  ];
  const vitals = extractWebVitals(events);
  assert.deepEqual(vitals.LCP, { value: 1200, rating: "good" });
  assert.deepEqual(vitals.CLS, { value: 0.05, rating: "good" });
  assert.deepEqual(vitals.INP, { value: 250, rating: "needs-improvement" });
});

test("extractWebVitals keeps the last value seen per metric", () => {
  const events = [perf("LCP", 1000, "good"), perf("LCP", 3000, "poor")];
  const vitals = extractWebVitals(events);
  assert.deepEqual(vitals.LCP, { value: 3000, rating: "poor" });
});

test("extractWebVitals ignores entries without a numeric value", () => {
  const events = [perf("LCP", "fast", "good")];
  const vitals = extractWebVitals(events);
  assert.equal(vitals.LCP, undefined);
});

// ── prototype pollution guard ────────────────────────────────────

test("extractWebVitals does not pollute Object.prototype via __proto__ metric", () => {
  const events = [perf("__proto__", 999, "poor")];
  extractWebVitals(events);
  // A fresh, unrelated object must not have gained a `value` property.
  assert.equal({}.value, undefined);
  assert.equal(Object.prototype.value, undefined);
});

test("extractWebVitals ignores a __proto__ metric and keeps a clean prototype", () => {
  // A malicious "__proto__" metric must not corrupt the accumulator's
  // prototype chain via the special __proto__ setter.
  const events = [
    perf("__proto__", 999, "poor"),
    perf("LCP", 1200, "good"),
  ];
  const vitals = extractWebVitals(events);
  // The accumulator's prototype must remain null (Object.create(null)),
  // not a metric object planted by the attacker.
  assert.equal(Object.getPrototypeOf(vitals), null);
  // The real metric is still captured normally.
  assert.deepEqual(vitals.LCP, { value: 1200, rating: "good" });
});

test("extractWebVitals does not pollute via constructor/prototype keys", () => {
  const events = [
    perf("constructor", 1, "poor"),
    perf("prototype", 2, "poor"),
  ];
  const vitals = extractWebVitals(events);
  // Object.prototype itself must remain unpolluted.
  assert.equal(Object.prototype.value, undefined);
  // The accumulator must not expose inherited keys as data.
  assert.equal(typeof vitals.LCP, "undefined");
});

// ── formatVitalValue ─────────────────────────────────────────────

test("formatVitalValue formats CLS as a 3-decimal unitless number", () => {
  assert.equal(formatVitalValue("CLS", 0.123456), "0.123");
});

test("formatVitalValue formats LCP/INP as whole milliseconds", () => {
  assert.equal(formatVitalValue("LCP", 1234.6), "1235 ms");
  assert.equal(formatVitalValue("INP", 250), "250 ms");
});
