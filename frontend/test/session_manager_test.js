import { test } from "node:test";
import assert from "node:assert/strict";

import { getSessionId, getWindowId, touchLastSeen, clearClientStorage } from "../src/session_manager.js";
import {
  DEFAULT_SESSION_IDLE_TIMEOUT_MS as DEFAULT_IDLE_TIMEOUT_MS,
  DEFAULT_SESSION_MAX_AGE_MS as DEFAULT_MAX_AGE_MS,
} from "../src/session_config.js";

// Minimal Storage stand-in (a jar), matching the style of the other tests.
function fakeStorage(initial = {}) {
  const jar = new Map(Object.entries(initial));
  return {
    getItem: (k) => (jar.has(k) ? jar.get(k) : null),
    setItem: (k, v) => jar.set(k, String(v)),
    removeItem: (k) => jar.delete(k),
    _jar: jar,
  };
}

function configElement(overrides) {
  return { textContent: JSON.stringify(overrides) };
}

// Patches globalThis.localStorage/sessionStorage/document for the duration of
// fn. document only exposes getElementById("sentiero-config"), matching what
// readSessionLimitsMs actually reads.
function withEnv({ localStorage, sessionStorage, config = {} }, fn) {
  const g = globalThis;
  const saved = {
    localStorage: Object.getOwnPropertyDescriptor(g, "localStorage"),
    sessionStorage: Object.getOwnPropertyDescriptor(g, "sessionStorage"),
    document: Object.getOwnPropertyDescriptor(g, "document"),
  };
  const doc = {
    getElementById: (id) => (id === "sentiero-config" ? configElement(config) : null),
  };
  try {
    Object.defineProperty(g, "localStorage", { value: localStorage, configurable: true });
    Object.defineProperty(g, "sessionStorage", { value: sessionStorage, configurable: true });
    Object.defineProperty(g, "document", { value: doc, configurable: true });
    return fn();
  } finally {
    for (const [k, d] of Object.entries(saved)) {
      if (d) Object.defineProperty(g, k, d);
      else delete g[k];
    }
  }
}

test("creates a fresh session id with created_at/last_seen timestamps on first call", () => {
  const ls = fakeStorage();
  withEnv({ localStorage: ls, sessionStorage: fakeStorage() }, () => {
    const before = Date.now();
    const id = getSessionId(true);
    assert.equal(ls.getItem("sentiero_session_id"), id);
    assert.ok(Number(ls.getItem("sentiero_session_created_at")) >= before);
    assert.ok(Number(ls.getItem("sentiero_session_last_seen")) >= before);
  });
});

test("reuses the id within the idle/max-age window and bumps last_seen", () => {
  const now = Date.now();
  const ls = fakeStorage({
    sentiero_session_id: "existing-id",
    sentiero_session_created_at: String(now - 60_000),
    sentiero_session_last_seen: String(now - 60_000),
  });
  withEnv({ localStorage: ls, sessionStorage: fakeStorage() }, () => {
    const id = getSessionId(true);
    assert.equal(id, "existing-id");
    assert.ok(Number(ls.getItem("sentiero_session_last_seen")) >= now);
  });
});

test("rotates once the idle timeout has elapsed since last_seen", () => {
  const now = Date.now();
  const ls = fakeStorage({
    sentiero_session_id: "stale-id",
    sentiero_session_created_at: String(now - 5_000),
    sentiero_session_last_seen: String(now - (DEFAULT_IDLE_TIMEOUT_MS + 1)),
    sentiero_entry_url: "https://ex.com/",
    sentiero_entry_referrer: "",
  });
  withEnv({ localStorage: ls, sessionStorage: fakeStorage() }, () => {
    const id = getSessionId(true);
    assert.notEqual(id, "stale-id");
    assert.equal(ls.getItem("sentiero_entry_url"), null, "a rotated id starts a fresh entry page too");
    assert.equal(ls.getItem("sentiero_entry_referrer"), null);
  });
});

test("rotates once max_age has elapsed since created_at, even if recently active", () => {
  const now = Date.now();
  const ls = fakeStorage({
    sentiero_session_id: "old-id",
    sentiero_session_created_at: String(now - (DEFAULT_MAX_AGE_MS + 1)),
    sentiero_session_last_seen: String(now - 1_000),
  });
  withEnv({ localStorage: ls, sessionStorage: fakeStorage() }, () => {
    const id = getSessionId(true);
    assert.notEqual(id, "old-id");
  });
});

test("a corrupt created_at forces rotation even when the id and last_seen look valid", () => {
  const now = Date.now();
  const ls = fakeStorage({
    sentiero_session_id: "corrupt-id",
    sentiero_session_created_at: "not-a-number",
    sentiero_session_last_seen: String(now),
  });
  withEnv({ localStorage: ls, sessionStorage: fakeStorage() }, () => {
    const id = getSessionId(true);
    assert.notEqual(id, "corrupt-id");
  });
});

test("a missing last_seen forces rotation even when the id and created_at look valid", () => {
  const now = Date.now();
  const ls = fakeStorage({
    sentiero_session_id: "half-written-id",
    sentiero_session_created_at: String(now),
  });
  withEnv({ localStorage: ls, sessionStorage: fakeStorage() }, () => {
    const id = getSessionId(true);
    assert.notEqual(id, "half-written-id");
  });
});

test("honors sessionIdleTimeoutMs from the config element", () => {
  const now = Date.now();
  const ls = fakeStorage({
    sentiero_session_id: "id-1",
    sentiero_session_created_at: String(now - 5_000),
    sentiero_session_last_seen: String(now - 2_000),
  });
  // 2s idle is well within the default 30 min window, but over a configured 1s one.
  withEnv({ localStorage: ls, sessionStorage: fakeStorage(), config: { sessionIdleTimeoutMs: 1_000 } }, () => {
    const id = getSessionId(true);
    assert.notEqual(id, "id-1");
  });
});

test("falls back to the built-in defaults when the config element has malformed limits", () => {
  const now = Date.now();
  const ls = fakeStorage({
    sentiero_session_id: "id-1",
    sentiero_session_created_at: String(now - 5_000),
    sentiero_session_last_seen: String(now - 2_000),
  });
  withEnv(
    { localStorage: ls, sessionStorage: fakeStorage(), config: { sessionIdleTimeoutMs: "soon", sessionMaxAgeMs: -1 } },
    () => {
      const id = getSessionId(true);
      assert.equal(id, "id-1", "malformed config values fall back to defaults rather than forcing rotation");
    },
  );
});

test("non-cross-tab mode stores the session id in sessionStorage instead", () => {
  const ss = fakeStorage();
  withEnv({ localStorage: fakeStorage(), sessionStorage: ss }, () => {
    const id = getSessionId(false);
    assert.equal(ss.getItem("sentiero_session_id"), id);
  });
});

test("getWindowId returns a stable per-tab id with no rotation bookkeeping", () => {
  const ss = fakeStorage();
  withEnv({ localStorage: fakeStorage(), sessionStorage: ss }, () => {
    const first = getWindowId();
    const second = getWindowId();
    assert.equal(first, second);
    assert.equal(ss.getItem("sentiero_session_created_at"), null);
  });
});

test("touchLastSeen refreshes last_seen for the storage used by the most recent getSessionId call", () => {
  const ls = fakeStorage();
  withEnv({ localStorage: ls, sessionStorage: fakeStorage() }, () => {
    getSessionId(true);
    const original = Number(ls.getItem("sentiero_session_last_seen"));
    ls.setItem("sentiero_session_last_seen", String(original - 5_000));
    touchLastSeen();
    assert.ok(Number(ls.getItem("sentiero_session_last_seen")) > original - 5_000);
  });
});

test("touchLastSeen is a no-op before any getSessionId call", () => {
  clearClientStorage(); // also resets the module's remembered active storage
  assert.doesNotThrow(() => touchLastSeen());
});

test("falls back to an in-memory id, reused for the page, when storage throws", () => {
  const throwing = {
    getItem() { throw new Error("blocked"); },
    setItem() { throw new Error("blocked"); },
    removeItem() { throw new Error("blocked"); },
  };
  withEnv({ localStorage: throwing, sessionStorage: fakeStorage() }, () => {
    const first = getSessionId(true);
    const second = getSessionId(true);
    assert.equal(first, second);
  });
});

test("clearClientStorage removes every key this module writes, from both storages", () => {
  const ls = fakeStorage({
    sentiero_session_id: "id",
    sentiero_session_created_at: "1",
    sentiero_session_last_seen: "1",
    sentiero_entry_url: "https://ex.com/",
    sentiero_entry_referrer: "",
    sentiero_optout: "1", // a different key, owned by opt_out.js — must survive
  });
  const ss = fakeStorage({ sentiero_window_id: "win-1" });

  withEnv({ localStorage: ls, sessionStorage: ss }, () => {
    clearClientStorage();
  });

  for (const key of [
    "sentiero_session_id",
    "sentiero_session_created_at",
    "sentiero_session_last_seen",
    "sentiero_entry_url",
    "sentiero_entry_referrer",
  ]) {
    assert.equal(ls.getItem(key), null, `${key} should be cleared`);
  }
  assert.equal(ss.getItem("sentiero_window_id"), null);
  assert.equal(ls.getItem("sentiero_optout"), "1", "the opt-out marker is a different key and must survive");
});

test("clearClientStorage tolerates missing storages", () => {
  withEnv({ localStorage: undefined, sessionStorage: undefined }, () => {
    assert.doesNotThrow(() => clearClientStorage());
  });
});
