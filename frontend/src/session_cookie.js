// Mirrors the session/window id into first-party cookies so the server-side
// reporter middleware can link server exceptions to the front-end replay. The
// cookie names are a contract with the Ruby reporter. Called only after the
// shouldRecord() gate, so opted-out/GPC users never get these cookies.

import { readSessionLimitsMs } from "./session_config.js";

export const SESSION_COOKIE = "sentiero_sid";
export const WINDOW_COOKIE = "sentiero_wid";

function writeCookie(doc, name, value, secure, maxAgeSeconds) {
  let cookie = `${name}=${encodeURIComponent(value)}; path=/; max-age=${maxAgeSeconds}; SameSite=Lax`;
  if (secure) cookie += "; Secure";
  doc.cookie = cookie;
}

// Called once per page load (recorder.js init), which is also exactly when a
// session id rotation decision is made — so the cookie's lifetime rides the
// current session_max_age and is naturally rewritten on every rotation.
export function mirrorSessionCookies(
  sessionId,
  windowId,
  { doc = globalThis.document, secure = globalThis.location?.protocol === "https:" } = {},
) {
  if (!doc || !sessionId) return;
  const maxAgeSeconds = Math.round(readSessionLimitsMs().maxAgeMs / 1000);
  try {
    writeCookie(doc, SESSION_COOKIE, sessionId, secure, maxAgeSeconds);
    if (windowId) writeCookie(doc, WINDOW_COOKIE, windowId, secure, maxAgeSeconds);
  } catch {
    // document.cookie can be blocked (sandboxed iframe, privacy mode); ignore.
  }
}

export function clearSessionCookies({ doc = globalThis.document } = {}) {
  if (!doc) return;
  try {
    doc.cookie = `${SESSION_COOKIE}=; path=/; max-age=0; SameSite=Lax`;
    doc.cookie = `${WINDOW_COOKIE}=; path=/; max-age=0; SameSite=Lax`;
  } catch {
    // ignore
  }
}
