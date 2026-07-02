import { test } from "node:test";
import assert from "node:assert/strict";

import {
  FORM_SUBMIT_TAG,
  formIdentity,
  formSubmitPayload,
  setupFormSubmitTracking,
} from "../src/form_tracking.js";

// Minimal stand-in for document so the capture-phase submit listener can be
// exercised under node without a DOM (mirrors opt_out_test.js conventions).
function fakeDoc() {
  const listeners = [];
  return {
    addEventListener(type, fn, capture) {
      listeners.push({ type, fn, capture });
    },
    dispatch(type, event) {
      for (const l of listeners) {
        if (l.type === type) l.fn(event);
      }
    },
    listeners,
  };
}

// A form element stand-in exposing only attributes (the listener must never
// read values). `value`/`elements` exist to prove they are NOT consulted.
function fakeForm(attrs = {}) {
  return {
    getAttribute: (name) => (name in attrs ? attrs[name] : null),
    elements: [{ name: "email", value: "carla@example.com" }],
    value: "should-never-appear",
  };
}

// ── formIdentity ─────────────────────────────────────────────────

test("formIdentity carries name and id attributes only", () => {
  const form = fakeForm({ name: "signup", id: "signup-form" });
  assert.deepEqual(formIdentity(form), { name: "signup", id: "signup-form" });
});

test("formIdentity omits absent or empty attributes", () => {
  assert.deepEqual(formIdentity(fakeForm({})), {});
  assert.deepEqual(formIdentity(fakeForm({ name: "", id: "only-id" })), { id: "only-id" });
});

test("formIdentity returns empty identity for a non-element target", () => {
  assert.deepEqual(formIdentity(null), {});
  assert.deepEqual(formIdentity({}), {});
});

// ── formSubmitPayload ────────────────────────────────────────────

test("formSubmitPayload is identity plus the page url", () => {
  const form = fakeForm({ name: "signup" });
  assert.deepEqual(formSubmitPayload(form, "https://x.test/signup"), {
    name: "signup",
    url: "https://x.test/signup",
  });
});

test("formSubmitPayload never contains field values", () => {
  const form = fakeForm({ name: "signup", id: "f1" });
  const payload = formSubmitPayload(form, "https://x.test/signup");
  const json = JSON.stringify(payload);
  assert.doesNotMatch(json, /carla@example\.com/);
  assert.doesNotMatch(json, /should-never-appear/);
  assert.deepEqual(Object.keys(payload).sort(), ["id", "name", "url"]);
});

// ── setupFormSubmitTracking ──────────────────────────────────────

test("setup registers a capture-phase document submit listener", () => {
  const doc = fakeDoc();
  setupFormSubmitTracking(doc, () => {}, () => "https://x.test/");
  assert.equal(doc.listeners.length, 1);
  assert.equal(doc.listeners[0].type, "submit");
  assert.equal(doc.listeners[0].capture, true);
});

test("a submit emits __form_submit with form identity and page url", () => {
  const doc = fakeDoc();
  const emitted = [];
  setupFormSubmitTracking(
    doc,
    (tag, payload) => emitted.push({ tag, payload }),
    () => "https://x.test/signup",
  );

  doc.dispatch("submit", { target: fakeForm({ name: "signup", id: "f1" }) });

  assert.equal(emitted.length, 1);
  assert.equal(emitted[0].tag, FORM_SUBMIT_TAG);
  assert.deepEqual(emitted[0].payload, {
    name: "signup",
    id: "f1",
    url: "https://x.test/signup",
  });
});

test("a submit from an anonymous form still emits, with url only", () => {
  const doc = fakeDoc();
  const emitted = [];
  setupFormSubmitTracking(
    doc,
    (tag, payload) => emitted.push({ tag, payload }),
    () => "https://x.test/app",
  );

  doc.dispatch("submit", { target: fakeForm({}) });

  assert.deepEqual(emitted, [
    { tag: FORM_SUBMIT_TAG, payload: { url: "https://x.test/app" } },
  ]);
});

test("a submit with a non-element target is ignored", () => {
  const doc = fakeDoc();
  const emitted = [];
  setupFormSubmitTracking(doc, (tag) => emitted.push(tag), () => "https://x.test/");

  doc.dispatch("submit", { target: null });
  doc.dispatch("submit", {});

  assert.equal(emitted.length, 0);
});

test("an emit failure never propagates to the page", () => {
  const doc = fakeDoc();
  setupFormSubmitTracking(
    doc,
    () => {
      throw new Error("recorder gone");
    },
    () => "https://x.test/",
  );

  assert.doesNotThrow(() => doc.dispatch("submit", { target: fakeForm({}) }));
});
