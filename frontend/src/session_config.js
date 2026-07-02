// Session rotation/cookie-lifetime settings, read directly from the
// recorder's own config element rather than threaded through as a
// parameter. session_manager.js and session_cookie.js are each called from
// call sites (transport.js, recorder.js) that predate this option, so
// reading it here keeps both self-contained without changing those
// signatures. Mirrors Sentiero::Configuration#session_idle_timeout /
// #session_max_age (seconds on the Ruby side; ms here, since the client
// compares directly against Date.now()).

export const DEFAULT_SESSION_IDLE_TIMEOUT_MS = 6 * 60 * 60 * 1000;
export const DEFAULT_SESSION_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;

function positiveNumber(value, fallback) {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : fallback;
}

export function readSessionLimitsMs() {
  let raw = {};
  try {
    const el = globalThis.document?.getElementById?.("sentiero-config");
    if (el) raw = JSON.parse(el.textContent) || {};
  } catch {
    raw = {};
  }
  return {
    idleTimeoutMs: positiveNumber(raw.sessionIdleTimeoutMs, DEFAULT_SESSION_IDLE_TIMEOUT_MS),
    maxAgeMs: positiveNumber(raw.sessionMaxAgeMs, DEFAULT_SESSION_MAX_AGE_MS),
  };
}
