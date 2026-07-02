// rrweb event type constants
export const TYPE_INCREMENTAL = 3;
export const TYPE_META = 4;
export const TYPE_CUSTOM = 5;

// rrweb IncrementalSource constants
export const SOURCE_MUTATION = 0;
export const SOURCE_MOUSE_INTERACTION = 2;
export const SOURCE_SCROLL = 3;
export const SOURCE_INPUT = 5;

// rrweb MouseInteraction subtypes
export const MOUSE_CLICK = 2;
export const MOUSE_CONTEXTMENU = 3;
export const MOUSE_DBLCLICK = 4;
export const MOUSE_TOUCHSTART = 7;

export const EVENT_CATEGORIES = {
  navigation: { label: "Navigation", color: "#198754" },
  click: { label: "Click", color: "#dc3545" },
  input: { label: "Input", color: "#0d6efd" },
  error: { label: "Error", color: "#ff0000" },
  custom: { label: "Custom", color: "#6f42c1" },
  frustration: { label: "Frustration", color: "#ff6b6b" },
  server_exception: { label: "Server Exception", color: "#b91c1c" },
  server_event: { label: "Server Event", color: "#7c3aed" },
};

export const PAGE_SIZE = 1000;

export const IDLE_GAP_THRESHOLD_MS = 5000;
export const IDLE_GAP_BAR_PCT = 3;

export function computeActiveTime(events) {
  if (events.length < 2) return 0;

  let activeMs = 0;
  let burstStart = events[0].timestamp;
  let prev = events[0].timestamp;

  for (let i = 1; i < events.length; i++) {
    const ts = events[i].timestamp;
    if (ts - prev > IDLE_GAP_THRESHOLD_MS) {
      activeMs += prev - burstStart;
      burstStart = ts;
    }
    prev = ts;
  }
  activeMs += prev - burstStart;

  return activeMs;
}

export function formatDuration(ms) {
  const totalSeconds = Math.round(ms / 1000);
  if (totalSeconds < 60) return `${totalSeconds}s`;
  if (totalSeconds < 3600) {
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;
    return seconds > 0 ? `${minutes}m ${seconds}s` : `${minutes}m`;
  }
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  return minutes > 0 ? `${hours}h ${minutes}m` : `${hours}h`;
}

export function formatTimeOffset(ms) {
  const totalSeconds = Math.floor(ms / 1000);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  const pad = (n) => (n < 10 ? "0" : "") + n;
  if (hours > 0) {
    return `${hours}:${pad(minutes)}:${pad(seconds)}`;
  }
  return `${minutes}:${pad(seconds)}`;
}

export function truncate(str, max) {
  if (str.length <= max) return str;
  return str.substring(0, max - 3) + "...";
}

export function extractViewport(events) {
  for (let i = 0; i < events.length; i++) {
    if (events[i].type === TYPE_META && events[i].data) {
      const w = events[i].data.width;
      const h = events[i].data.height;
      if (w && h) return `${w}x${h}`;
    }
  }
  return null;
}
