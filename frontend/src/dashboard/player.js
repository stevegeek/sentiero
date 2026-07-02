import { computeActiveTime, formatDuration, extractViewport } from "./utils.js";
import { fetchAllEvents, buildSignificantEvents, getTimelineMapping } from "./events.js";
import { renderMarkerBar, updatePlayhead } from "./markers.js";
import { renderActivitySidebar } from "./sidebar.js";
import { renderWebVitalBadges } from "./web_vitals.js";
import { renderScrollDepthBadge } from "./scroll-depth.js";
import { initClickOverlay } from "./click_overlay.js";
import { detectFrustrationEvents } from "./frustration.js";

let _playerInstance = null;
let _loadedEvents = [];
const _speeds = [1, 2, 4, 8, 16];
let _currentSpeedIndex = 0;
let _keyboardShortcutsInitialized = false;

export function getPlayerInstance() {
  return _playerInstance;
}

export function getLoadedEvents() {
  return _loadedEvents;
}

function showActiveTime(events) {
  const el = document.getElementById("active-time");
  if (!el) return;
  const activeMs = computeActiveTime(events);
  if (activeMs > 0) {
    const totalMs = events[events.length - 1].timestamp - events[0].timestamp;
    const pct = totalMs > 0 ? Math.round((activeMs / totalMs) * 100) : 100;
    el.textContent = `(active: ${formatDuration(activeMs)} / ${pct}%)`;
    el.style.display = "inline";
  }
}

function showViewport(events) {
  const el = document.getElementById("viewport-info");
  if (!el) return;
  const viewport = extractViewport(events);
  if (viewport) {
    el.textContent = `Viewport: ${viewport}`;
    el.style.display = "inline";
  }
}

function getStartTimestamp(events) {
  if (events.length === 0) return null;
  const params = new URLSearchParams(window.location.search);
  const t = params.get("t");
  if (t !== null && t !== "") {
    const absMs = parseInt(t, 10);
    if (!isNaN(absMs)) {
      const offset = absMs - events[0].timestamp;
      return offset >= 0 ? events[0].timestamp + offset : null;
    }
  }
  return null;
}

export function seekToOffset(offsetMs) {
  if (!_playerInstance) return;
  try {
    const replayer = _playerInstance.getReplayer();
    if (replayer) {
      replayer.play(offsetMs);
      replayer.pause();
    }
  } catch (e) {
    console.warn("Sentiero: seek failed", e);
  }
}

function seekRelative(replayer, deltaMs) {
  try {
    const meta = replayer.getMetaData();
    const current = replayer.getCurrentTime();
    const target = Math.max(0, Math.min(current + deltaMs, meta.totalTime));
    replayer.play(target);
    replayer.pause();
  } catch (e) {
    console.warn("Sentiero: seek failed", e);
  }
}

function changeSpeed(direction) {
  _currentSpeedIndex = Math.max(
    0,
    Math.min(_speeds.length - 1, _currentSpeedIndex + direction)
  );
  try {
    const replayer = _playerInstance.getReplayer();
    if (replayer && replayer.setConfig) {
      replayer.setConfig({ speed: _speeds[_currentSpeedIndex] });
    }
  } catch (e) {
    console.warn("Sentiero: speed change failed", e);
  }
}

function initKeyboardShortcuts() {
  if (_keyboardShortcutsInitialized) return;
  _keyboardShortcutsInitialized = true;
  document.addEventListener("keydown", (e) => {
    if (!_playerInstance) return;
    if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA") return;

    let replayer;
    try {
      replayer = _playerInstance.getReplayer();
    } catch (err) {
      return;
    }
    if (!replayer) return;

    switch (e.key) {
      case " ":
        e.preventDefault();
        try {
          if (_playerInstance.$$?.ctx?.[0]) {
            _playerInstance.toggle();
          } else {
            replayer.play();
          }
        } catch (err) {
          try {
            replayer.play();
          } catch (e2) {
            /* ignore */
          }
        }
        break;
      case "ArrowLeft":
        e.preventDefault();
        seekRelative(replayer, -5000);
        break;
      case "ArrowRight":
        e.preventDefault();
        seekRelative(replayer, 5000);
        break;
      case "ArrowUp":
        e.preventDefault();
        changeSpeed(1);
        break;
      case "ArrowDown":
        e.preventDefault();
        changeSpeed(-1);
        break;
    }
  });
}

export function initPlayer(eventsUrl, container, serverMarkers = []) {
  if (!container) {
    console.error("Sentiero: player container not found");
    return;
  }

  fetchAllEvents(eventsUrl, (error, events) => {
    if (error) {
      console.error("Sentiero: failed to load events", error);
      container.innerHTML = "";
      const alertDiv = document.createElement("div");
      alertDiv.className = "alert alert-danger";
      alertDiv.textContent = `Failed to load session events: ${error.message}`;
      container.appendChild(alertDiv);
      return;
    }

    if (events.length === 0) {
      container.innerHTML =
        '<p class="text-muted">No events recorded for this window.</p>';
      return;
    }

    _loadedEvents = events;

    showActiveTime(events);
    showViewport(events);
    renderScrollDepthBadge(events, document.getElementById("scroll-depth-info"));
    renderWebVitalBadges(events, document.getElementById("web-vitals-badges"));

    const significantEvents = buildSignificantEvents(events);
    const mapping = getTimelineMapping();
    const firstTs = events[0].timestamp;
    const frustrationEvents = detectFrustrationEvents(events);
    frustrationEvents.forEach((fe) => {
      fe.position = mapping ? mapping.map(fe.timestamp) : 0;
    });
    // Server-activity markers carry server-computed offsets (player ms space);
    // derive their bar position from the timeline mapping like frustration events.
    const serverEvents = Array.isArray(serverMarkers) ? serverMarkers : [];
    serverEvents.forEach((sm) => {
      sm.position = mapping ? mapping.map(firstTs + sm.offset) : 0;
    });
    const merged = significantEvents
      .concat(frustrationEvents)
      .concat(serverEvents)
      .sort((a, b) => a.offset - b.offset);
    renderMarkerBar(merged, events);
    renderActivitySidebar(merged);

    const frameEl = container.closest(".player-frame") || container.parentElement;
    const availableWidth = frameEl ? frameEl.clientWidth : 1024;
    const playerWidth = Math.min(2048, availableWidth);

    const Player = rrwebPlayer.default || rrwebPlayer;
    _playerInstance = new Player({
      target: container,
      props: {
        events: events,
        showController: true,
        autoPlay: false,
        skipInactive: true,
        width: playerWidth,
      },
    });

    const startTs = getStartTimestamp(events);
    if (startTs) {
      try {
        const replayer = _playerInstance.getReplayer();
        if (replayer) {
          setTimeout(() => {
            replayer.play(startTs - events[0].timestamp);
            replayer.pause();
          }, 100);
        }
      } catch (e) {
        console.warn("Sentiero: could not seek to timestamp", e);
      }
    }

    initClickOverlay();
    initKeyboardShortcuts();
  });
}
