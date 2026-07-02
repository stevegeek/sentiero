import { readSessionLimitsMs } from "./session_config.js";

const SESSION_ID_KEY = "sentiero_session_id";
const WINDOW_ID_KEY = "sentiero_window_id";
const SESSION_CREATED_KEY = "sentiero_session_created_at";
const SESSION_LAST_SEEN_KEY = "sentiero_session_last_seen";
const ENTRY_URL_KEY = "sentiero_entry_url";
const ENTRY_REFERRER_KEY = "sentiero_entry_referrer";

// Every localStorage/sessionStorage key this module writes, for clearClientStorage.
const ALL_STORAGE_KEYS = [
  SESSION_ID_KEY,
  WINDOW_ID_KEY,
  SESSION_CREATED_KEY,
  SESSION_LAST_SEEN_KEY,
  ENTRY_URL_KEY,
  ENTRY_REFERRER_KEY,
];

const _sessionFallback = { value: null };
const _windowFallback = { value: null };

// Storage object backing the currently active session id, remembered so
// touchLastSeen can refresh it (e.g. on pagehide) without re-resolving
// crossTab mode.
let _activeStorage = null;

function getOrCreateId(storage, key, fallback) {
  try {
    let id = storage.getItem(key);
    if (!id) {
      id = crypto.randomUUID();
      storage.setItem(key, id);
    }
    return id;
  } catch {
    if (!fallback.value) {
      fallback.value = crypto.randomUUID();
    }
    return fallback.value;
  }
}

function readTimestamp(storage, key) {
  const raw = Number(storage.getItem(key));
  return Number.isFinite(raw) && raw > 0 ? raw : null;
}

function writeTimestamp(storage, key, value) {
  storage.setItem(key, String(value));
}

// A session id rotates once it has been idle too long or has simply lived
// too long, so a returning visitor eventually gets a fresh identifier
// instead of one permanent cross-visit tracking id (and so server-side
// retention purge, keyed on session activity, can eventually reclaim it).
// Missing or corrupt created_at/last_seen timestamps are treated as expired:
// an id with no verifiable provenance can't be trusted to still be current.
export function getSessionId(crossTab = true) {
  const storage = crossTab ? localStorage : sessionStorage;
  const { idleTimeoutMs, maxAgeMs } = readSessionLimitsMs();

  try {
    const now = Date.now();
    const existingId = storage.getItem(SESSION_ID_KEY);
    const createdAt = readTimestamp(storage, SESSION_CREATED_KEY);
    const lastSeen = readTimestamp(storage, SESSION_LAST_SEEN_KEY);

    const expired = !existingId || createdAt === null || lastSeen === null ||
      now - lastSeen > idleTimeoutMs || now - createdAt > maxAgeMs;

    let id = existingId;
    if (expired) {
      id = crypto.randomUUID();
      storage.setItem(SESSION_ID_KEY, id);
      writeTimestamp(storage, SESSION_CREATED_KEY, now);
      // A rotated id starts a new session; the previous identity's entry
      // page must not carry over onto it.
      storage.removeItem(ENTRY_URL_KEY);
      storage.removeItem(ENTRY_REFERRER_KEY);
    }
    writeTimestamp(storage, SESSION_LAST_SEEN_KEY, now);

    _activeStorage = storage;
    return id;
  } catch {
    if (!_sessionFallback.value) {
      _sessionFallback.value = crypto.randomUUID();
    }
    return _sessionFallback.value;
  }
}

export function getWindowId() {
  return getOrCreateId(sessionStorage, WINDOW_ID_KEY, _windowFallback);
}

// getSessionId only runs once per Transport construction (i.e. once per page
// load), so a tab left open past the idle timeout would otherwise look
// abandoned when the user returns to it. Exported so callers/tests can
// trigger it directly; also wired to pagehide below since that's the only
// other point in this session's lifecycle where activity is known.
export function touchLastSeen() {
  if (!_activeStorage) return;
  try {
    writeTimestamp(_activeStorage, SESSION_LAST_SEEN_KEY, Date.now());
  } catch {
    // storage may be blocked (private mode / sandboxed iframe); ignore.
  }
}

if (typeof window !== "undefined" && typeof window.addEventListener === "function") {
  window.addEventListener("pagehide", touchLastSeen);
}

// Origin + pathname only. getEntryMetadata is called from transport.js's
// _collectMetadata, which does not have the parsed redaction config
// available at that call site, so query/fragment (the parts most likely to
// carry PII or tracking identifiers) are stripped unconditionally rather
// than persisted raw in storage for the life of the session.
function originAndPath(urlString) {
  if (!urlString) return "";
  try {
    const url = new URL(urlString);
    return url.origin + url.pathname;
  } catch {
    const cut = urlString.search(/[?#]/);
    return cut === -1 ? urlString : urlString.slice(0, cut);
  }
}

// Entry url + referrer captured once on first page load, returned unchanged
// thereafter; stored alongside the session id.
export function getEntryMetadata(crossTab = true) {
  const storage = crossTab ? localStorage : sessionStorage;
  try {
    const existing = storage.getItem(ENTRY_URL_KEY);
    if (existing === null) {
      const url = originAndPath(globalThis.location?.href || "");
      const referrer = originAndPath(globalThis.document?.referrer || "");
      storage.setItem(ENTRY_URL_KEY, url);
      storage.setItem(ENTRY_REFERRER_KEY, referrer);
      return { entry_url: url, entry_referrer: referrer };
    }
    return { entry_url: existing, entry_referrer: storage.getItem(ENTRY_REFERRER_KEY) || "" };
  } catch {
    return {};
  }
}

// Removes every client-side identifier this module writes, from BOTH
// localStorage and sessionStorage (crossTab mode determines which one is
// live, but clearing both is cheap and avoids leaving residue behind if the
// setting ever changes). Called from recorder.js's opt-out handler so an
// opt-out -> opt-in cycle starts a genuinely fresh session rather than
// silently resuming the old identifier.
export function clearClientStorage() {
  for (const storage of [globalThis.localStorage, globalThis.sessionStorage]) {
    if (!storage) continue;
    for (const key of ALL_STORAGE_KEYS) {
      try {
        storage.removeItem(key);
      } catch {
        // ignore
      }
    }
  }
  _activeStorage = null;
}
