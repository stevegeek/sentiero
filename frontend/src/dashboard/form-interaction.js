import { TYPE_INCREMENTAL, SOURCE_INPUT, IDLE_GAP_THRESHOLD_MS } from "./utils.js";

// Client-side analysis of loaded rrweb input events (type 3, source 5).
// Privacy: keys fields by rrweb nodeId, never reads or displays values (works
// with maskAllInputs); re-fill/toggle counts come from event counts, not values.

function isInput(ev) {
  return !!(
    ev &&
    ev.type === TYPE_INCREMENTAL &&
    ev.data &&
    ev.data.source === SOURCE_INPUT &&
    typeof ev.data.id === "number"
  );
}

function isToggleData(data) {
  return !!data && typeof data.isChecked === "boolean";
}

export function analyzeFormInteractions(events) {
  if (!Array.isArray(events)) return [];

  const byNode = new Map();
  for (let i = 0; i < events.length; i++) {
    const ev = events[i];
    if (!isInput(ev)) continue;
    const id = ev.data.id;
    let summary = byNode.get(id);
    if (!summary) {
      summary = {
        nodeId: id,
        fillCount: 0,
        isToggle: false,
        firstTimestamp: ev.timestamp,
        lastTimestamp: ev.timestamp,
      };
      byNode.set(id, summary);
    }
    summary.fillCount += 1;
    summary.lastTimestamp = ev.timestamp;
    if (isToggleData(ev.data)) summary.isToggle = true;
  }

  const summaries = Array.from(byNode.values()).sort(
    (a, b) => a.firstTimestamp - b.firstTimestamp
  );
  summaries.forEach((s, i) => {
    s.order = i + 1;
    s.label = `Field ${i + 1}`;
  });
  return summaries;
}

export function buildFormContext(events) {
  const summaries = analyzeFormInteractions(events);
  const byNodeId = {};
  const sequence = [];
  for (let i = 0; i < summaries.length; i++) {
    const s = summaries[i];
    const next = summaries[i + 1];
    s.nextFieldOffset = next ? next.firstTimestamp - s.firstTimestamp : null;
    byNodeId[s.nodeId] = s;
    sequence.push(s.label);
  }
  return { totalFields: summaries.length, sequence, byNodeId };
}

function formatGap(ms) {
  if (ms < 1000) return `${Math.round(ms / 100) * 100}ms`;
  return `${(Math.round(ms / 100) / 10).toFixed(1)}s`;
}

export function getFormInteractionDetail(se, formContext) {
  if (!se || se.category !== "input") return [];
  if (!formContext || !formContext.byNodeId) return [];
  const data = se.event && se.event.data;
  if (!data || typeof data.id !== "number") return [];

  const summary = formContext.byNodeId[data.id];
  if (!summary) return [];

  const lines = [`Field ${summary.order} of ${formContext.totalFields}`];

  if (summary.isToggle) {
    if (summary.fillCount > 1) lines.push(`Toggled: ${summary.fillCount} times`);
  } else if (summary.fillCount > 1) {
    lines.push(`Re-filled: ${summary.fillCount} times`);
  }

  if (
    summary.nextFieldOffset != null &&
    summary.nextFieldOffset > 0 &&
    summary.nextFieldOffset <= IDLE_GAP_THRESHOLD_MS
  ) {
    lines.push(`Time to next field: ${formatGap(summary.nextFieldOffset)}`);
  }

  return lines;
}
