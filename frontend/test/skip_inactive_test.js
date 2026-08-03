import { test } from "node:test";
import assert from "node:assert/strict";

import {
  computeInactiveRanges,
  findJumpTarget,
  installInactiveSkipper,
  INACTIVE_GAP_MS,
  JUMP_LEAD_MS,
} from "../src/dashboard/skip_inactive.js";

const T0 = 1700000000000;

function fullSnapshot(ts) {
  return { type: 2, timestamp: ts, data: { node: {}, initialOffset: { left: 0, top: 0 } } };
}

function click(ts) {
  return { type: 3, timestamp: ts, data: { source: 2, type: 2, id: 1, x: 0, y: 0 } };
}

function mousemove(ts) {
  return { type: 3, timestamp: ts, data: { source: 1, positions: [] } };
}

function mutation(ts) {
  return { type: 3, timestamp: ts, data: { source: 0, adds: [], removes: [], attributes: [], texts: [] } };
}

function custom(ts) {
  return { type: 5, timestamp: ts, data: { tag: "navigation", payload: {} } };
}

// ── computeInactiveRanges ────────────────────────────────────────

test("returns empty for empty or interaction-free sessions", () => {
  assert.deepEqual(computeInactiveRanges([]), []);
  assert.deepEqual(computeInactiveRanges([fullSnapshot(T0), mutation(T0 + 60000)]), []);
});

test("detects a gap between two interactions", () => {
  const events = [fullSnapshot(T0), click(T0 + 1000), click(T0 + 61000)];
  assert.deepEqual(computeInactiveRanges(events), [{ start: 1000, end: 61000 }]);
});

test("ignores gaps at or below the threshold", () => {
  const events = [fullSnapshot(T0), click(T0), click(T0 + INACTIVE_GAP_MS)];
  assert.deepEqual(computeInactiveRanges(events), []);
});

test("mutations and custom events inside a gap do not break it", () => {
  const events = [
    fullSnapshot(T0),
    click(T0 + 1000),
    mutation(T0 + 20000),
    custom(T0 + 40000),
    click(T0 + 61000),
  ];
  assert.deepEqual(computeInactiveRanges(events), [{ start: 1000, end: 61000 }]);
});

test("mousemove counts as activity and splits a gap", () => {
  const events = [fullSnapshot(T0), click(T0 + 1000), mousemove(T0 + 8000), click(T0 + 16000)];
  assert.deepEqual(computeInactiveRanges(events), []);
});

test("includes the head gap before the first interaction", () => {
  const events = [fullSnapshot(T0), click(T0 + 30000)];
  assert.deepEqual(computeInactiveRanges(events), [{ start: 0, end: 30000 }]);
});

test("includes the tail gap after the last interaction", () => {
  const events = [fullSnapshot(T0), click(T0 + 1000), mutation(T0 + 90000)];
  assert.deepEqual(computeInactiveRanges(events), [{ start: 1000, end: 90000 }]);
});

// ── findJumpTarget ───────────────────────────────────────────────

const RANGES = [{ start: 1000, end: 61000 }];

test("returns end minus lead when current time is inside a range", () => {
  assert.equal(findJumpTarget(RANGES, 5000), 61000 - JUMP_LEAD_MS);
});

test("returns null outside any range", () => {
  assert.equal(findJumpTarget(RANGES, 500), null);
  assert.equal(findJumpTarget(RANGES, 61500), null);
});

test("returns null once within the lead margin of the range end", () => {
  assert.equal(findJumpTarget(RANGES, 61000 - JUMP_LEAD_MS), null);
  assert.equal(findJumpTarget(RANGES, 60900), null);
});

// ── installInactiveSkipper ───────────────────────────────────────

function fakePlayer({ skipInactive = true } = {}) {
  const handlers = {};
  const gotoCalls = [];
  return {
    addEventListener(name, fn) {
      handlers[name] = fn;
    },
    goto(t, play) {
      gotoCalls.push([t, play]);
    },
    getReplayer() {
      return { config: { skipInactive } };
    },
    emit(name, payload) {
      handlers[name]?.({ payload });
    },
    gotoCalls,
  };
}

const SESSION = [fullSnapshot(T0), click(T0 + 1000), click(T0 + 61000)];

test("jumps over a gap while playing", () => {
  const player = fakePlayer();
  installInactiveSkipper(player, SESSION);
  player.emit("ui-update-player-state", "playing");
  player.emit("ui-update-current-time", 5000);
  assert.deepEqual(player.gotoCalls, [[61000 - JUMP_LEAD_MS, true]]);
});

test("does not jump while paused", () => {
  const player = fakePlayer();
  installInactiveSkipper(player, SESSION);
  player.emit("ui-update-current-time", 5000);
  player.emit("ui-update-player-state", "paused");
  player.emit("ui-update-current-time", 6000);
  assert.deepEqual(player.gotoCalls, []);
});

test("respects the skip-inactive toggle being off", () => {
  const player = fakePlayer({ skipInactive: false });
  installInactiveSkipper(player, SESSION);
  player.emit("ui-update-player-state", "playing");
  player.emit("ui-update-current-time", 5000);
  assert.deepEqual(player.gotoCalls, []);
});

test("does nothing for sessions without inactive ranges", () => {
  const player = fakePlayer();
  installInactiveSkipper(player, [fullSnapshot(T0), click(T0 + 1000)]);
  player.emit("ui-update-player-state", "playing");
  player.emit("ui-update-current-time", 500);
  assert.deepEqual(player.gotoCalls, []);
});
