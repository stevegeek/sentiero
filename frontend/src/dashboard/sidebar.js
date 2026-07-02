import {
  EVENT_CATEGORIES,
  IDLE_GAP_THRESHOLD_MS,
  formatTimeOffset,
  formatDuration,
} from "./utils.js";
import { describeEvent, getEventDetailLines } from "./events.js";
import { seekToOffset, getPlayerInstance } from "./player.js";
import { updatePlayhead } from "./markers.js";

let _playbackInterval = null;
let _significantEventsRef = [];

export function renderActivitySidebar(significantEvents) {
  const sidebar = document.getElementById("activity-sidebar");
  const list = document.getElementById("activity-list");
  const countEl = document.getElementById("activity-count");
  if (!sidebar || !list) return;
  if (significantEvents.length === 0) {
    sidebar.style.display = "none";
    return;
  }

  _significantEventsRef = significantEvents;
  sidebar.style.display = "";
  if (countEl) countEl.textContent = significantEvents.length;
  list.innerHTML = "";

  significantEvents.forEach((se, i) => {
    const cat = EVENT_CATEGORIES[se.category];
    if (!cat) return;

    if (i > 0) {
      const prevOffset = significantEvents[i - 1].offset;
      const gapMs = se.offset - prevOffset;
      if (gapMs > IDLE_GAP_THRESHOLD_MS) {
        const gapDiv = document.createElement("div");
        gapDiv.className = "activity-gap";
        gapDiv.textContent = `${formatDuration(gapMs)} inactive`;
        list.appendChild(gapDiv);
      }
    }

    const wrapper = document.createElement("div");
    wrapper.className = "activity-wrapper";

    const entry = document.createElement("div");
    let entryClass = "activity-entry";
    if (se.category === "error") entryClass += " error-entry";
    else if (se.category === "navigation") entryClass += " navigation-entry";
    else if (se.category === "frustration") entryClass += " frustration-entry";
    else if (se.category === "server_exception") entryClass += " server-exception-entry";
    else if (se.category === "server_event") entryClass += " server-event-entry";
    entry.className = entryClass;
    entry.setAttribute("data-offset", se.offset);
    entry.setAttribute("data-index", i);

    const time = document.createElement("span");
    time.className = "activity-time";
    time.textContent = formatTimeOffset(se.offset);

    const dot = document.createElement("span");
    dot.className = "activity-dot";
    dot.style.backgroundColor = cat.color;

    let label;
    if (se.isServerMarker && se.href) {
      label = document.createElement("a");
      label.href = se.href;
      label.className = "activity-label activity-label-link";
      label.addEventListener("click", (e) => e.stopPropagation());
    } else {
      label = document.createElement("span");
      label.className = "activity-label";
    }
    label.textContent = describeEvent(se);

    entry.appendChild(time);
    entry.appendChild(dot);
    entry.appendChild(label);

    entry.addEventListener("click", () => seekToOffset(se.offset));

    wrapper.appendChild(entry);

    const detailLines = getEventDetailLines(se);
    if (detailLines.length > 0) {
      const detail = document.createElement("div");
      detail.className = "activity-detail";
      detailLines.forEach((line) => {
        const p = document.createElement("div");
        p.className = "activity-detail-line";
        if (line.indexOf("\n") !== -1) {
          const pre = document.createElement("pre");
          pre.className = "activity-detail-pre";
          pre.textContent = line;
          p.appendChild(pre);
        } else {
          p.textContent = line;
        }
        detail.appendChild(p);
      });
      wrapper.appendChild(detail);
    }

    list.appendChild(wrapper);
  });

  startPlaybackTracking();
}

export function stopPlaybackTracking() {
  if (_playbackInterval) {
    clearInterval(_playbackInterval);
    _playbackInterval = null;
  }
}

export function startPlaybackTracking() {
  stopPlaybackTracking();
  _playbackInterval = setInterval(() => {
    const playerInstance = getPlayerInstance();
    if (!playerInstance) return;
    try {
      const replayer = playerInstance.getReplayer();
      const currentTime = replayer.getCurrentTime();
      highlightCurrentActivity(currentTime);
      updatePlayhead(currentTime);
    } catch (e) {
      /* ignore */
    }
  }, 250);
}

export function highlightCurrentActivity(currentTimeMs) {
  const wrappers = document.querySelectorAll(".activity-wrapper");
  if (wrappers.length === 0) return;

  let activeIndex = -1;
  for (let i = _significantEventsRef.length - 1; i >= 0; i--) {
    if (_significantEventsRef[i].offset <= currentTimeMs) {
      activeIndex = i;
      break;
    }
  }

  for (let j = 0; j < wrappers.length; j++) {
    const entry = wrappers[j].querySelector(".activity-entry");
    if (!entry) continue;
    if (j === activeIndex) {
      if (!entry.classList.contains("active")) {
        entry.classList.add("active");
        wrappers[j].scrollIntoView({ block: "nearest", behavior: "smooth" });
      }
    } else {
      entry.classList.remove("active");
    }
  }
}
