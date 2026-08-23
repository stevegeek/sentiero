import { test } from "node:test";
import assert from "node:assert/strict";

import { revealInPanel } from "../src/dashboard/sidebar.js";

// `row` is the viewport-relative position; the panel sits at viewport top 100.
function row(top, height) {
  return { getBoundingClientRect: () => ({ top, height }) };
}

function panel(scrollTop, clientHeight) {
  const calls = [];
  return {
    scrollTop, clientHeight, calls,
    getBoundingClientRect: () => ({ top: 100 }),
    scrollTo: (o) => calls.push(o),
  };
}

test("revealInPanel leaves the panel alone when the row is already visible", () => {
  const p = panel(0, 300);
  revealInPanel(p, row(150, 40));
  assert.deepEqual(p.calls, []);
});

test("revealInPanel scrolls the panel up to a row above the visible area", () => {
  const p = panel(400, 300);
  revealInPanel(p, row(50, 40));
  assert.deepEqual(p.calls, [{ top: 350, behavior: "smooth" }]);
});

test("revealInPanel scrolls the panel down to a row below the visible area", () => {
  const p = panel(0, 300);
  revealInPanel(p, row(500, 40));
  assert.deepEqual(p.calls, [{ top: 140, behavior: "smooth" }]);
});

test("revealInPanel ignores a missing panel", () => {
  assert.doesNotThrow(() => revealInPanel(null, row(0, 1)));
});
