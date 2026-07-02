import { TYPE_INCREMENTAL, TYPE_META, SOURCE_SCROLL } from "./utils.js";

// Max vertical scroll offset (px) across rrweb scroll events (type 3 / source 3);
// 0 when none.
export function maxScrollY(events) {
  let max = 0;
  if (!Array.isArray(events)) return max;
  for (let i = 0; i < events.length; i++) {
    const ev = events[i];
    if (
      ev &&
      ev.type === TYPE_INCREMENTAL &&
      ev.data &&
      ev.data.source === SOURCE_SCROLL &&
      typeof ev.data.y === "number" &&
      ev.data.y > max
    ) {
      max = ev.data.y;
    }
  }
  return max;
}

function viewportHeight(events) {
  if (!Array.isArray(events)) return null;
  for (let i = 0; i < events.length; i++) {
    const ev = events[i];
    if (ev && ev.type === TYPE_META && ev.data && ev.data.height) {
      return ev.data.height;
    }
  }
  return null;
}

// rrweb meta events carry viewport height but NOT document height, so a true
// 0-100% can't be derived. `viewports` is instead how many viewport heights the
// viewport bottom reached ((y + vh) / vh), a multiple (e.g. 3.1), not a percent;
// null when no viewport recorded. Whole result null when no scroll events.
export function computeScrollDepth(events) {
  const y = maxScrollY(events);
  if (y <= 0) return null;
  const vh = viewportHeight(events);
  const viewports = vh && vh > 0 ? Math.round(((y + vh) / vh) * 10) / 10 : null;
  return { y, viewports };
}

// Uses a "× viewport" unit, not "%", since the value is an unbounded multiple
// (document height is unknown). Hidden when no scroll was recorded.
export function renderScrollDepthBadge(events, container) {
  if (!container) return;
  const depth = computeScrollDepth(events);
  if (!depth) {
    container.style.display = "none";
    container.textContent = "";
    return;
  }
  const vp = depth.viewports != null ? ` (~${depth.viewports}× viewport)` : "";
  container.textContent = `Max Scroll: ${depth.y}px${vp}`;
  container.style.display = "inline";
}
