import {
  PAGE_SIZE,
  TYPE_INCREMENTAL,
  TYPE_META,
  TYPE_CUSTOM,
  SOURCE_MOUSE_INTERACTION,
  SOURCE_INPUT,
  MOUSE_CLICK,
  MOUSE_CONTEXTMENU,
  MOUSE_DBLCLICK,
  MOUSE_TOUCHSTART,
  EVENT_CATEGORIES,
  IDLE_GAP_THRESHOLD_MS,
  IDLE_GAP_BAR_PCT,
  formatTimeOffset,
  truncate,
} from "./utils.js";
import { getFormInteractionDetail, buildFormContext } from "./form-interaction.js";

export function fetchAllEvents(url, callback) {
  let allEvents = [];
  let currentUrl = url;

  function fetchPage() {
    fetch(currentUrl)
      .then((response) => {
        if (!response.ok) {
          throw new Error(`Failed to fetch events: ${response.status}`);
        }
        return response.json();
      })
      .then((events) => {
        if (!Array.isArray(events) || events.length === 0) {
          callback(null, allEvents);
          return;
        }

        allEvents = allEvents.concat(events);

        if (events.length < PAGE_SIZE) {
          callback(null, allEvents);
          return;
        }

        const lastEvent = events[events.length - 1];
        if (lastEvent && lastEvent.timestamp) {
          const sep = url.indexOf("?") === -1 ? "?" : "&";
          currentUrl = `${url}${sep}after=${lastEvent.timestamp}`;
          fetchPage();
        } else {
          callback(null, allEvents);
        }
      })
      .catch((error) => {
        if (allEvents.length > 0) {
          callback(null, allEvents);
        } else {
          callback(error, []);
        }
      });
  }

  fetchPage();
}

let _timelineMapping = null;

export function getTimelineMapping() {
  return _timelineMapping;
}

export function classifyEvent(event) {
  if (event.type === TYPE_META && event.data && event.data.href) {
    return "navigation";
  }
  if (event.type === TYPE_INCREMENTAL && event.data) {
    if (event.data.source === SOURCE_MOUSE_INTERACTION) {
      const mouseType = event.data.type;
      if (
        mouseType === MOUSE_CLICK ||
        mouseType === MOUSE_DBLCLICK ||
        mouseType === MOUSE_CONTEXTMENU ||
        mouseType === MOUSE_TOUCHSTART
      ) {
        return "click";
      }
      return null;
    }
    if (event.data.source === SOURCE_INPUT) {
      return "input";
    }
  }
  if (event.type === TYPE_CUSTOM) {
    if (event.data && event.data.tag === "error") {
      return "error";
    }
    if (event.data && event.data.tag === "navigation") {
      return "navigation";
    }
    return "custom";
  }
  return null;
}

// Build a non-linear time mapping that compresses idle gaps.
// Returns { map(timestamp) -> 0..1, gaps: [{posStart, posEnd, duration}] }
function buildTimelineMapping(events) {
  if (!events || events.length < 2) {
    return { map: () => 0, gaps: [] };
  }

  const firstTs = events[0].timestamp;
  const lastTs = events[events.length - 1].timestamp;
  const totalDuration = lastTs - firstTs;

  if (totalDuration <= 0) {
    return { map: () => 0, gaps: [] };
  }

  const gaps = [];
  const segments = [];
  let segStart = firstTs;

  for (let i = 1; i < events.length; i++) {
    const delta = events[i].timestamp - events[i - 1].timestamp;
    if (delta > IDLE_GAP_THRESHOLD_MS) {
      segments.push({ start: segStart, end: events[i - 1].timestamp });
      gaps.push({ start: events[i - 1].timestamp, end: events[i].timestamp, duration: delta });
      segStart = events[i].timestamp;
    }
  }
  segments.push({ start: segStart, end: lastTs });

  if (gaps.length === 0) {
    return {
      map: (ts) => (ts - firstTs) / totalDuration,
      gaps: [],
    };
  }

  let totalActive = 0;
  for (let s = 0; s < segments.length; s++) {
    totalActive += segments[s].end - segments[s].start;
  }

  let totalGapPct = gaps.length * IDLE_GAP_BAR_PCT;
  // Cap gap space so active segments always get majority of bar
  if (totalGapPct > 40) {
    totalGapPct = 40;
  }
  const gapPctEach = totalGapPct / gaps.length;
  const activePct = 100 - totalGapPct;

  const ranges = [];
  let pos = 0;
  for (let si = 0; si < segments.length; si++) {
    const segDuration = segments[si].end - segments[si].start;
    const segPct = totalActive > 0 ? (segDuration / totalActive) * activePct : 0;
    ranges.push({
      type: "active",
      start: segments[si].start,
      end: segments[si].end,
      posStart: pos,
      posEnd: pos + segPct,
    });
    pos += segPct;

    if (si < gaps.length) {
      ranges.push({
        type: "gap",
        start: gaps[si].start,
        end: gaps[si].end,
        duration: gaps[si].duration,
        posStart: pos,
        posEnd: pos + gapPctEach,
      });
      pos += gapPctEach;
    }
  }

  function mapTimestamp(ts) {
    for (let r = 0; r < ranges.length; r++) {
      const range = ranges[r];
      if (range.type === "active" && ts >= range.start && ts <= range.end) {
        const segLen = range.end - range.start;
        const fraction = segLen > 0 ? (ts - range.start) / segLen : 0;
        return (range.posStart + fraction * (range.posEnd - range.posStart)) / 100;
      }
    }
    // Timestamp inside a gap maps to the gap's start edge.
    for (let g = 0; g < ranges.length; g++) {
      if (ranges[g].type === "gap" && ts >= ranges[g].start && ts <= ranges[g].end) {
        return ranges[g].posStart / 100;
      }
    }
    if (ts <= firstTs) return 0;
    return 1;
  }

  const gapRanges = ranges.filter((r) => r.type === "gap");

  return { map: mapTimestamp, gaps: gapRanges };
}

export function buildSignificantEvents(events) {
  if (!events || events.length === 0) return [];
  const firstTs = events[0].timestamp;

  _timelineMapping = buildTimelineMapping(events);

  // Computed once and shared by reference across input entries so form-interaction
  // detail panels reuse one analysis pass.
  const formContext = buildFormContext(events);

  let metaEventCount = 0;
  const result = [];
  for (let i = 0; i < events.length; i++) {
    const cat = classifyEvent(events[i]);
    if (!cat) continue;
    const se = {
      index: i,
      timestamp: events[i].timestamp,
      offset: events[i].timestamp - firstTs,
      position: _timelineMapping.map(events[i].timestamp),
      category: cat,
      event: events[i],
    };
    if (cat === "navigation" && events[i].type === TYPE_META) {
      metaEventCount++;
      se.metaIndex = metaEventCount;
    }
    if (cat === "input") {
      se.formContext = formContext;
    }
    result.push(se);
  }
  return result;
}

// Adapt server-activity markers (from the #server-activity-markers JSON island)
// into the significant-event shape. offset_ms is already in player ms space and
// used directly as `offset`; `position` is left for the player to derive from the
// timeline mapping after events load (like frustration events).
export function adaptServerMarkers(rawMarkers) {
  if (!Array.isArray(rawMarkers)) return [];
  return rawMarkers.map((m) => ({
    offset: m.offset_ms || 0,
    category: m.kind === "exception" ? "server_exception" : "server_event",
    kind: m.kind,
    label: m.label || "",
    level: m.level || "",
    href: m.href || null,
    isServerMarker: true,
  }));
}

export function isToggleInput(data) {
  return typeof data.isChecked === "boolean";
}

export function describeEvent(se) {
  if (se.isServerMarker) {
    return se.label || (se.category === "server_exception" ? "Server exception" : "Server event");
  }
  // rrweb Meta event (type 4) - page load/reload
  if (se.category === "navigation" && se.event.data && se.event.data.href) {
    const href = se.event.data.href;
    try {
      const path = truncate(new URL(href).pathname, 40);
      return se.metaIndex === 1 ? `Page loaded: ${path}` : `Navigated to: ${path}`;
    } catch (e) {
      return se.metaIndex === 1 ? "Page loaded" : "Page navigation";
    }
  }
  if (se.category === "navigation" && se.event.data && se.event.data.payload) {
    const p = se.event.data.payload;
    const url = p.url || "";
    const label = p.external ? "Leaving to: " : "Navigating to: ";
    try {
      const parsed = new URL(url);
      const display = p.external ? parsed.hostname + parsed.pathname : parsed.pathname;
      return label + truncate(display, 40);
    } catch (e) {
      return label + truncate(url, 40);
    }
  }
  if (se.category === "click" && se.event.data) {
    const mouseType = se.event.data.type;
    let clickLabel = "Click";
    if (mouseType === MOUSE_DBLCLICK) clickLabel = "Double Click";
    else if (mouseType === MOUSE_CONTEXTMENU) clickLabel = "Right Click";
    else if (mouseType === MOUSE_TOUCHSTART) clickLabel = "Touch";
    if (se.event.data.x != null && se.event.data.y != null) {
      clickLabel += ` (${Math.round(se.event.data.x)}, ${Math.round(se.event.data.y)})`;
    }
    return clickLabel;
  }
  if (se.category === "input" && se.event.data) {
    const d = se.event.data;
    if (typeof d.text === "string" && d.text.length > 0 && !isToggleInput(d)) {
      return `Input: ${truncate(d.text, 20)}`;
    }
    if (isToggleInput(d)) {
      return d.isChecked ? "Checkbox checked" : "Checkbox unchecked";
    }
    return "Input cleared";
  }
  if (se.category === "frustration") {
    const coords =
      se.x != null && se.y != null ? ` (${Math.round(se.x)}, ${Math.round(se.y)})` : "";
    if (se.subtype === "rage_click") {
      return `Rage click${coords}`;
    }
    return `Dead click${coords}`;
  }
  if (se.category === "error" && se.event.data && se.event.data.payload) {
    const msg = se.event.data.payload.message || "Error";
    return truncate(msg, 50);
  }
  if (se.category === "custom" && se.event.data && se.event.data.tag) {
    return se.event.data.tag;
  }
  const cat = EVENT_CATEGORIES[se.category];
  return cat ? cat.label : "Event";
}

export function getEventDetailLines(se) {
  if (se.isServerMarker) {
    const lines = [];
    if (se.level) lines.push(`Level: ${se.level}`);
    if (se.href) lines.push(`Details: ${se.href}`);
    return lines;
  }

  const lines = [];
  const d = se.event.data || {};

  if (se.category === "frustration") {
    if (se.x != null && se.y != null) {
      lines.push(`Position: (${Math.round(se.x)}, ${Math.round(se.y)})`);
    }
    if (se.subtype === "rage_click") {
      lines.push(`Clicks: ${se.count}`);
    } else {
      lines.push(`No response within ${se.elapsed || 500}ms`);
    }
    return lines;
  }
  if (se.category === "navigation") {
    if (d.href) {
      lines.push(`URL: ${d.href}`);
      if (d.width && d.height) lines.push(`Viewport: ${d.width}x${d.height}`);
    } else if (d.payload) {
      if (d.payload.url) lines.push(`URL: ${d.payload.url}`);
      if (d.payload.text) lines.push(`Link text: ${d.payload.text}`);
      if (d.payload.external) lines.push("External link");
    }
    return lines;
  }
  if (se.category === "click") {
    if (d.x != null && d.y != null) {
      lines.push(`Position: (${Math.round(d.x)}, ${Math.round(d.y)})`);
    }
  } else if (se.category === "input") {
    if (typeof d.text === "string" && d.text.length > 0) {
      lines.push(`Value: ${d.text}`);
    }
    if (isToggleInput(d)) {
      lines.push(`Checked: ${d.isChecked}`);
    }
    getFormInteractionDetail(se, se.formContext).forEach((l) => lines.push(l));
  } else if (se.category === "error" && d.payload) {
    const p = d.payload;
    if (p.message) lines.push(`Message: ${p.message}`);
    if (p.source) {
      let loc = p.source;
      if (p.lineno) loc += `:${p.lineno}`;
      if (p.colno) loc += `:${p.colno}`;
      lines.push(`Source: ${loc}`);
    }
    if (p.type) lines.push(`Type: ${p.type}`);
    if (p.stack) lines.push(`Stack:\n${p.stack}`);
  } else if (se.category === "custom" && d.payload) {
    try {
      lines.push(`Payload: ${JSON.stringify(d.payload, null, 2)}`);
    } catch (e) {
      lines.push("Payload: [object]");
    }
  }

  return lines;
}
