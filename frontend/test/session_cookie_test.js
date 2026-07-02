import { test } from "node:test";
import assert from "node:assert/strict";

import {
  mirrorSessionCookies,
  clearSessionCookies,
  SESSION_COOKIE,
  WINDOW_COOKIE,
} from "../src/session_cookie.js";

// Minimal document.cookie stand-in (a jar), matching the style of opt_out_test.
function fakeDoc(initial = "") {
  const jar = new Map();
  if (initial) {
    for (const pair of initial.split(";")) {
      const idx = pair.indexOf("=");
      jar.set(pair.slice(0, idx).trim(), pair.slice(idx + 1).trim());
    }
  }
  return {
    writes: [],
    get cookie() {
      return [...jar].map(([k, v]) => `${k}=${v}`).join("; ");
    },
    set cookie(str) {
      this.writes.push(str);
      const [pair] = str.split(";");
      const idx = pair.indexOf("=");
      const key = pair.slice(0, idx).trim();
      const value = pair.slice(idx + 1).trim();
      if (/max-age=0\b/.test(str)) {
        jar.delete(key);
      } else {
        jar.set(key, value);
      }
    },
  };
}

test("mirrorSessionCookies sets session and window cookies", () => {
  const doc = fakeDoc();
  mirrorSessionCookies("sess_1", "win_1", { doc, secure: false });
  assert.match(doc.cookie, /sentiero_sid=sess_1/);
  assert.match(doc.cookie, /sentiero_wid=win_1/);
});

test("cookies use path=/ and SameSite=Lax", () => {
  const doc = fakeDoc();
  mirrorSessionCookies("sess_1", "win_1", { doc, secure: false });
  for (const w of doc.writes) {
    assert.match(w, /path=\//);
    assert.match(w, /SameSite=Lax/);
  }
});

test("secure flag is added only when secure is true", () => {
  const insecure = fakeDoc();
  mirrorSessionCookies("s", "w", { doc: insecure, secure: false });
  assert.ok(!insecure.writes.some((w) => /;\s*Secure/i.test(w)));

  const secure = fakeDoc();
  mirrorSessionCookies("s", "w", { doc: secure, secure: true });
  assert.ok(secure.writes.every((w) => /;\s*Secure/i.test(w)));
});

test("window cookie is skipped when windowId is missing", () => {
  const doc = fakeDoc();
  mirrorSessionCookies("sess_only", null, { doc, secure: false });
  assert.match(doc.cookie, /sentiero_sid=sess_only/);
  assert.ok(!/sentiero_wid=/.test(doc.cookie));
});

test("no session id is a no-op (does not throw, writes nothing)", () => {
  const doc = fakeDoc();
  mirrorSessionCookies(null, null, { doc, secure: false });
  assert.equal(doc.writes.length, 0);
});

test("clearSessionCookies expires both cookies", () => {
  const doc = fakeDoc("sentiero_sid=sess_1; sentiero_wid=win_1");
  clearSessionCookies({ doc });
  assert.ok(!/sentiero_sid=/.test(doc.cookie));
  assert.ok(!/sentiero_wid=/.test(doc.cookie));
});

test("exports the agreed cookie names", () => {
  assert.equal(SESSION_COOKIE, "sentiero_sid");
  assert.equal(WINDOW_COOKIE, "sentiero_wid");
});

// Patches globalThis.document to expose a #sentiero-config element, matching
// what readSessionLimitsMs actually reads (separate from the `doc` option
// mirrorSessionCookies writes cookies to).
function withGlobalConfig(config, fn) {
  const g = globalThis;
  const saved = Object.getOwnPropertyDescriptor(g, "document");
  Object.defineProperty(g, "document", {
    value: { getElementById: (id) => (id === "sentiero-config" ? { textContent: JSON.stringify(config) } : null) },
    configurable: true,
  });
  try {
    return fn();
  } finally {
    if (saved) Object.defineProperty(g, "document", saved);
    else delete g.document;
  }
}

test("cookie max-age defaults to the 7-day session_max_age default with no config element", () => {
  const doc = fakeDoc();
  mirrorSessionCookies("sess_1", "win_1", { doc, secure: false });
  assert.match(doc.writes[0], /max-age=604800\b/);
});

test("cookie max-age uses the configured sessionMaxAgeMs from the config element", () => {
  withGlobalConfig({ sessionMaxAgeMs: 3_600_000 }, () => {
    const doc = fakeDoc();
    mirrorSessionCookies("sess_1", "win_1", { doc, secure: false });
    assert.match(doc.writes[0], /max-age=3600\b/);
  });
});

test("a thrown cookie setter never propagates", () => {
  const throwingDoc = {
    set cookie(_v) {
      throw new Error("blocked");
    },
    get cookie() {
      return "";
    },
  };
  // must not throw
  mirrorSessionCookies("s", "w", { doc: throwingDoc, secure: false });
  clearSessionCookies({ doc: throwingDoc });
});
