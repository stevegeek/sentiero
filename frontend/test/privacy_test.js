import { test } from "node:test";
import assert from "node:assert/strict";

import { shouldRecord } from "../src/config.js";

// A navigator-like object that advertises (or omits) a Global Privacy Control
// signal. Passed explicitly so the test never mutates the real global.
function makeNav(globalPrivacyControl) {
  return { globalPrivacyControl };
}

test("records when respect_gpc is off, even if the browser sends GPC", () => {
  assert.equal(shouldRecord({}, makeNav(true)), true);
});

test("records when respect_gpc is on but the browser sends no GPC signal", () => {
  assert.equal(shouldRecord({ respectGpc: true }, makeNav(false)), true);
});

test("records when respect_gpc is on but GPC is undefined (unsupported)", () => {
  assert.equal(shouldRecord({ respectGpc: true }, makeNav(undefined)), true);
});

test("does not record when respect_gpc is on and the browser sends GPC", () => {
  assert.equal(shouldRecord({ respectGpc: true }, makeNav(true)), false);
});
