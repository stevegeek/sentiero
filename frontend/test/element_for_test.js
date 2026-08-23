import { test } from "node:test";
import assert from "node:assert/strict";

import { elementFor } from "../src/recorder.js";

const el = { nodeType: 1, closest: () => null };

test("elementFor returns an element target unchanged", () => {
  assert.equal(elementFor(el), el);
});

test("elementFor walks a text node up to its parent element", () => {
  assert.equal(elementFor({ nodeType: 3, parentElement: el }), el);
});

test("elementFor returns null for document, window, null and undefined targets", () => {
  assert.equal(elementFor({ nodeType: 9 }), null);
  assert.equal(elementFor({}), null);
  assert.equal(elementFor(null), null);
  assert.equal(elementFor(undefined), null);
});
