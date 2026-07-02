import {
  TYPE_INCREMENTAL,
  TYPE_META,
  SOURCE_MOUSE_INTERACTION,
  SOURCE_MUTATION,
  SOURCE_INPUT,
  MOUSE_CLICK,
} from "./utils.js";

// Frustration detection — client-side analysis of loaded rrweb events, surfacing
// two activity-sidebar signals: rage clicks (>=3 clicks within 500ms at ~same
// coords) and dead clicks (a click with no DOM response within 500ms).
// These thresholds are the canonical source mirrored by the Ruby port.

const RAGE_WINDOW_MS = 500; // max span of a rage cluster, and gap between clicks
const RAGE_COORD_TOLERANCE_PX = 10; // max coord drift from cluster's first click
const RAGE_MIN_CLICKS = 3; // clicks needed to count as a rage cluster
const DEAD_WINDOW_MS = 500; // window after a click to wait for a DOM response

function isClick(ev) {
  return !!(
    ev &&
    ev.type === TYPE_INCREMENTAL &&
    ev.data &&
    ev.data.source === SOURCE_MOUSE_INTERACTION &&
    ev.data.type === MOUSE_CLICK &&
    typeof ev.data.x === "number" &&
    typeof ev.data.y === "number"
  );
}

function isResponse(ev) {
  if (!ev || !ev.data) return false;
  if (ev.type === TYPE_META) return true;
  if (ev.type === TYPE_INCREMENTAL) {
    return ev.data.source === SOURCE_MUTATION || ev.data.source === SOURCE_INPUT;
  }
  return false;
}

// Rage cluster: RAGE_MIN_CLICKS+ clicks where each successive click is within
// RAGE_WINDOW_MS of both the previous click and the cluster's first click (whole
// burst fits one window), and within RAGE_COORD_TOLERANCE_PX of the first click.
export function detectRageClicks(events) {
  if (!Array.isArray(events)) return [];

  const clicks = [];
  for (let i = 0; i < events.length; i++) {
    if (isClick(events[i])) clicks.push(events[i]);
  }
  if (clicks.length < RAGE_MIN_CLICKS) return [];

  const out = [];
  let clusterStart = 0;
  for (let i = 1; i <= clicks.length; i++) {
    const prev = clicks[i - 1];
    const cur = clicks[i];
    const anchor = clicks[clusterStart];
    const continues =
      cur &&
      cur.timestamp - prev.timestamp <= RAGE_WINDOW_MS &&
      cur.timestamp - anchor.timestamp <= RAGE_WINDOW_MS &&
      Math.abs(cur.data.x - anchor.data.x) <= RAGE_COORD_TOLERANCE_PX &&
      Math.abs(cur.data.y - anchor.data.y) <= RAGE_COORD_TOLERANCE_PX;

    if (!continues) {
      const count = i - clusterStart;
      if (count >= RAGE_MIN_CLICKS) {
        const members = [];
        for (let k = clusterStart; k < i; k++) members.push(clicks[k].timestamp);
        out.push({
          subtype: "rage_click",
          timestamp: anchor.timestamp,
          count,
          x: anchor.data.x,
          y: anchor.data.y,
          memberTimestamps: members,
          event: anchor,
        });
      }
      clusterStart = i;
    }
  }
  return out;
}

// Dead click: a click with no mutation/input/navigation response strictly after
// it and within DEAD_WINDOW_MS (any such response makes the click "alive").
export function detectDeadClicks(events) {
  if (!Array.isArray(events)) return [];

  const out = [];
  for (let i = 0; i < events.length; i++) {
    if (!isClick(events[i])) continue;
    const clickTs = events[i].timestamp;
    const deadline = clickTs + DEAD_WINDOW_MS;

    let responded = false;
    for (let j = i + 1; j < events.length; j++) {
      const ts = events[j].timestamp;
      if (ts > deadline) break;
      if (ts > clickTs && isResponse(events[j])) {
        responded = true;
        break;
      }
    }

    if (!responded) {
      out.push({
        subtype: "dead_click",
        timestamp: clickTs,
        x: events[i].data.x,
        y: events[i].data.y,
        elapsed: DEAD_WINDOW_MS,
        event: events[i],
      });
    }
  }
  return out;
}

// Rage clusters take precedence: clicks already in a rage cluster are not also
// reported as dead clicks.
export function detectFrustrationEvents(events) {
  if (!Array.isArray(events) || events.length === 0) return [];
  const firstTs = events[0].timestamp;

  const rage = detectRageClicks(events);
  const dead = detectDeadClicks(events);

  const rageTimestamps = new Set();
  rage.forEach((r) => (r.memberTimestamps || [r.timestamp]).forEach((t) => rageTimestamps.add(t)));

  const combined = [];
  rage.forEach((r) => combined.push(r));
  dead.forEach((d) => {
    if (!rageTimestamps.has(d.timestamp)) combined.push(d);
  });

  return combined
    .map((entry) => ({
      category: "frustration",
      subtype: entry.subtype,
      timestamp: entry.timestamp,
      offset: entry.timestamp - firstTs,
      count: entry.count,
      elapsed: entry.elapsed,
      x: entry.x,
      y: entry.y,
      event: entry.event,
    }))
    .sort((a, b) => a.offset - b.offset);
}
