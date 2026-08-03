import { TYPE_INCREMENTAL } from "./utils.js";

// rrweb's Replayer only fast-forwards a gap when it exceeds
// SKIP_TIME_THRESHOLD (10s) multiplied by the current playback speed, so at
// 8x/16x most idle periods play through in real time. This module implements
// speed-independent skipping on top of rrweb-player: whenever playback enters
// a gap between user interactions it jumps straight to just before the next
// activity, honoring the player's own "skip inactive" toggle.

export const INACTIVE_GAP_MS = 10000;
export const JUMP_LEAD_MS = 1000;

// Mirrors rrweb's isUserInteraction: incremental sources MouseMove(1)
// through Input(5).
function isUserInteraction(event) {
  return (
    event.type === TYPE_INCREMENTAL &&
    event.data &&
    event.data.source >= 1 &&
    event.data.source <= 5
  );
}

// Inactive periods as {start, end} offsets (ms relative to the first event).
// A period is a gap longer than gapMs between consecutive user interactions,
// including the stretch before the first and after the last interaction.
// Sessions with no interactions at all yield no ranges: there is no
// "next activity" to skip to.
export function computeInactiveRanges(events, gapMs = INACTIVE_GAP_MS) {
  if (!Array.isArray(events) || events.length === 0) return [];

  const base = events[0].timestamp;
  const anchors = [0];
  let sawInteraction = false;
  for (const event of events) {
    if (isUserInteraction(event)) {
      anchors.push(event.timestamp - base);
      sawInteraction = true;
    }
  }
  if (!sawInteraction) return [];
  anchors.push(events[events.length - 1].timestamp - base);

  const ranges = [];
  for (let i = 1; i < anchors.length; i++) {
    if (anchors[i] - anchors[i - 1] > gapMs) {
      ranges.push({ start: anchors[i - 1], end: anchors[i] });
    }
  }
  return ranges;
}

// Where to jump from currentOffset, or null when not inside an inactive
// range (or already within leadMs of its end, so a jump can't re-trigger).
export function findJumpTarget(ranges, currentOffset, leadMs = JUMP_LEAD_MS) {
  for (const range of ranges) {
    const target = range.end - leadMs;
    if (currentOffset >= range.start && currentOffset < target) {
      return target;
    }
  }
  return null;
}

export function installInactiveSkipper(player, events) {
  const ranges = computeInactiveRanges(events);
  if (ranges.length === 0) return;

  let playing = false;
  player.addEventListener("ui-update-player-state", (event) => {
    playing = event.payload === "playing";
  });
  player.addEventListener("ui-update-current-time", (event) => {
    if (!playing) return;
    let skipEnabled;
    try {
      skipEnabled = player.getReplayer().config.skipInactive !== false;
    } catch (e) {
      return;
    }
    if (!skipEnabled) return;
    const target = findJumpTarget(ranges, event.payload);
    if (target !== null) player.goto(target, true);
  });
}
