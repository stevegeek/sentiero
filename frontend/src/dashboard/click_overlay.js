import {
  TYPE_INCREMENTAL,
  TYPE_META,
  SOURCE_MOUSE_INTERACTION,
  MOUSE_CLICK,
} from "./utils.js";
import { getPlayerInstance, getLoadedEvents } from "./player.js";

const DOT_RADIUS = 6;
const MAX_DOTS = 1000;

let _visible = false;
let _overlayEl = null;

// Click positions from rrweb mouse-click events (type 3 / source 2 / click).
export function extractClicks(events) {
  const clicks = [];
  if (!Array.isArray(events)) return clicks;
  for (let i = 0; i < events.length; i++) {
    const ev = events[i];
    if (
      ev &&
      ev.type === TYPE_INCREMENTAL &&
      ev.data &&
      ev.data.source === SOURCE_MOUSE_INTERACTION &&
      ev.data.type === MOUSE_CLICK &&
      typeof ev.data.x === "number" &&
      typeof ev.data.y === "number"
    ) {
      clicks.push({ x: ev.data.x, y: ev.data.y });
    }
  }
  return clicks;
}

// Recorded viewport from the first rrweb meta event.
export function extractViewportSize(events) {
  if (!Array.isArray(events)) return null;
  for (let i = 0; i < events.length; i++) {
    const ev = events[i];
    if (ev && ev.type === TYPE_META && ev.data && ev.data.width && ev.data.height) {
      return { width: ev.data.width, height: ev.data.height };
    }
  }
  return null;
}

// Scale a recorded click from viewport to display coordinates, clamped to bounds.
export function scaleClick(click, viewport, display) {
  const scaleX = viewport && viewport.width > 0 ? display.width / viewport.width : 1;
  const scaleY = viewport && viewport.height > 0 ? display.height / viewport.height : 1;
  const x = Math.max(0, Math.min(display.width, click.x * scaleX));
  const y = Math.max(0, Math.min(display.height, click.y * scaleY));
  return { x, y };
}

// The rrweb player's scaled wrapper, so the overlay aligns with replayed content.
function findReplayWrapper() {
  const container = document.getElementById("replayer");
  if (!container) return null;
  return container.querySelector(".replayer-wrapper") || container.querySelector(".rr-player__frame") || container;
}

function removeOverlay() {
  if (_overlayEl && _overlayEl.parentNode) {
    _overlayEl.parentNode.removeChild(_overlayEl);
  }
  _overlayEl = null;
}

function renderOverlay() {
  removeOverlay();

  const wrapper = findReplayWrapper();
  if (!wrapper) return;

  const events = getLoadedEvents();
  const viewport = extractViewportSize(events);
  let clicks = extractClicks(events);
  if (clicks.length > MAX_DOTS) {
    const step = Math.ceil(clicks.length / MAX_DOTS);
    clicks = clicks.filter((_, i) => i % step === 0);
  }

  const display = {
    width: wrapper.clientWidth || (viewport ? viewport.width : 0),
    height: wrapper.clientHeight || (viewport ? viewport.height : 0),
  };

  const overlay = document.createElement("div");
  overlay.className = "click-overlay-container";

  clicks.forEach((click) => {
    const { x, y } = scaleClick(click, viewport, display);
    const dot = document.createElement("div");
    dot.className = "click-dot";
    dot.style.left = `${x - DOT_RADIUS}px`;
    dot.style.top = `${y - DOT_RADIUS}px`;
    overlay.appendChild(dot);
  });

  if (getComputedStyle(wrapper).position === "static") {
    wrapper.style.position = "relative";
  }
  wrapper.appendChild(overlay);
  _overlayEl = overlay;
}

export function initClickOverlay() {
  _visible = false;
  removeOverlay();
  const btn = document.getElementById("toggle-clicks-btn");
  if (btn) {
    btn.setAttribute("aria-pressed", "false");
    btn.classList.remove("btn-active");
  }
}

export function toggleClickOverlay() {
  if (!getPlayerInstance()) return _visible;

  _visible = !_visible;
  if (_visible) {
    renderOverlay();
  } else {
    removeOverlay();
  }

  const btn = document.getElementById("toggle-clicks-btn");
  if (btn) {
    btn.setAttribute("aria-pressed", _visible ? "true" : "false");
    btn.classList.toggle("btn-active", _visible);
  }
  return _visible;
}
