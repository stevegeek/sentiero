import {
  EVENT_CATEGORIES,
  formatTimeOffset,
  formatDuration,
} from "./utils.js";
import { describeEvent, getTimelineMapping } from "./events.js";
import { seekToOffset } from "./player.js";

const GROUP_THRESHOLD_PCT = 1.5;
let _closeListenerAdded = false;
let _playheadEl = null;
let _firstTimestamp = 0;

export function groupMarkerEvents(markerEvents) {
  if (markerEvents.length === 0) return [];
  const groups = [];
  let current = { events: [markerEvents[0]], position: markerEvents[0].position * 100 };

  for (let i = 1; i < markerEvents.length; i++) {
    const pos = markerEvents[i].position * 100;
    if (Math.abs(pos - current.position) <= GROUP_THRESHOLD_PCT) {
      current.events.push(markerEvents[i]);
    } else {
      groups.push(current);
      current = { events: [markerEvents[i]], position: pos };
    }
  }
  groups.push(current);
  return groups;
}

export function closeAllMarkerDropdowns() {
  const open = document.querySelectorAll(".marker-dropdown");
  for (let i = 0; i < open.length; i++) {
    open[i].parentNode.removeChild(open[i]);
  }
}

export function updatePlayhead(currentTimeMs) {
  if (!_playheadEl) return;
  const mapping = getTimelineMapping();
  if (!mapping) return;
  const pos = mapping.map(_firstTimestamp + currentTimeMs) * 100;
  _playheadEl.style.left = `${Math.max(0, Math.min(100, pos))}%`;
}

export function renderMarkerBar(significantEvents, events) {
  const container = document.getElementById("event-markers");
  if (!container) return;
  if (significantEvents.length === 0) {
    container.style.display = "none";
    return;
  }

  if (events && events.length > 0) {
    _firstTimestamp = events[0].timestamp;
  }

  container.innerHTML = "";

  const legend = document.createElement("div");
  legend.className = "marker-legend";
  Object.keys(EVENT_CATEGORIES).forEach((key) => {
    const cat = EVENT_CATEGORIES[key];
    const item = document.createElement("span");
    item.className = "marker-legend-item";
    const dot = document.createElement("span");
    dot.className = "marker-legend-dot";
    dot.style.backgroundColor = cat.color;
    item.appendChild(dot);
    item.appendChild(document.createTextNode(cat.label));
    legend.appendChild(item);
  });
  container.appendChild(legend);

  const bar = document.createElement("div");
  bar.className = "marker-bar";

  const track = document.createElement("div");
  track.className = "marker-track";
  bar.appendChild(track);

  const playhead = document.createElement("div");
  playhead.className = "marker-playhead";
  playhead.style.left = "0%";
  bar.appendChild(playhead);
  _playheadEl = playhead;

  // Limit dots on the bar to avoid clutter
  let markerEvents = significantEvents;
  if (markerEvents.length > 500) {
    markerEvents = significantEvents.filter((se) => se.category !== "input");
  }

  const groups = groupMarkerEvents(markerEvents);

  groups.forEach((group) => {
    const pos = `${Math.max(1, Math.min(99, group.position))}%`;

    if (group.events.length === 1) {
      const se = group.events[0];
      const cat = EVENT_CATEGORIES[se.category];
      if (!cat) return;
      const dot = document.createElement("div");
      dot.className = `event-marker${se.category === "error" ? " error-marker" : ""}`;
      dot.style.left = pos;
      dot.style.backgroundColor = cat.color;
      dot.title = `${describeEvent(se)} at ${formatTimeOffset(se.offset)}`;
      dot.addEventListener("click", () => seekToOffset(se.offset));
      bar.appendChild(dot);
    } else {
      const hasError = group.events.some((e) => e.category === "error");
      const wrapper = document.createElement("div");
      wrapper.className = "marker-group";
      wrapper.style.left = pos;

      const groupDot = document.createElement("div");
      groupDot.className = `event-marker marker-group-dot${hasError ? " error-marker" : ""}`;
      groupDot.style.backgroundColor = hasError ? "#ff0000" : "#6c757d";
      groupDot.title = `${group.events.length} events at ${formatTimeOffset(group.events[0].offset)}`;

      const badge = document.createElement("span");
      badge.className = "marker-group-count";
      badge.textContent = group.events.length;

      wrapper.appendChild(groupDot);
      wrapper.appendChild(badge);

      wrapper.addEventListener("click", (e) => {
        e.stopPropagation();
        closeAllMarkerDropdowns();

        const dropdown = document.createElement("div");
        dropdown.className = "marker-dropdown";

        group.events.forEach((se) => {
          const cat = EVENT_CATEGORIES[se.category] || {};
          const item = document.createElement("div");
          item.className = `marker-dropdown-item${se.category === "error" ? " error-entry" : ""}`;

          const itemDot = document.createElement("span");
          itemDot.className = "activity-dot";
          itemDot.style.backgroundColor = cat.color || "#6c757d";

          const itemLabel = document.createElement("span");
          itemLabel.textContent = `${formatTimeOffset(se.offset)} ${describeEvent(se)}`;

          item.appendChild(itemDot);
          item.appendChild(itemLabel);
          item.addEventListener("click", (ev) => {
            ev.stopPropagation();
            closeAllMarkerDropdowns();
            seekToOffset(se.offset);
          });
          dropdown.appendChild(item);
        });

        wrapper.appendChild(dropdown);
      });

      bar.appendChild(wrapper);
    }
  });

  const timelineMapping = getTimelineMapping();
  if (timelineMapping && timelineMapping.gaps.length > 0) {
    timelineMapping.gaps.forEach((gap) => {
      const gapEl = document.createElement("div");
      gapEl.className = "marker-gap";
      gapEl.style.left = `${gap.posStart}%`;
      gapEl.style.width = `${gap.posEnd - gap.posStart}%`;
      gapEl.title = `Inactive: ${formatDuration(gap.duration)}`;
      bar.appendChild(gapEl);
    });
  }

  // Close dropdowns when clicking elsewhere (register only once)
  if (!_closeListenerAdded) {
    _closeListenerAdded = true;
    document.addEventListener("click", closeAllMarkerDropdowns);
  }

  container.appendChild(bar);
  container.style.display = "";
}
