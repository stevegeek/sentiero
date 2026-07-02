import { test } from "node:test";
import assert from "node:assert/strict";

import { hasOptedOut, optOut, optIn } from "../src/opt_out.js";

// Minimal stand-ins for document.cookie and localStorage so the pure opt-out
// helpers can be exercised under node without a DOM.
function fakeDoc(initial = "") {
  const jar = new Map();
  if (initial) {
    for (const pair of initial.split(";")) {
      const idx = pair.indexOf("=");
      jar.set(pair.slice(0, idx).trim(), pair.slice(idx + 1).trim());
    }
  }
  return {
    get cookie() {
      return [...jar].map(([k, v]) => `${k}=${v}`).join("; ");
    },
    set cookie(str) {
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

function fakeStorage(initial = {}) {
  const map = new Map(Object.entries(initial));
  return {
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, String(v)),
    removeItem: (k) => map.delete(k),
  };
}

test("hasOptedOut detects a truthy cookie", () => {
  const doc = fakeDoc("sentiero_optout=1");
  assert.equal(hasOptedOut("sentiero_optout", doc, fakeStorage()), true);
});

test("hasOptedOut detects a truthy localStorage key", () => {
  const storage = fakeStorage({ sentiero_optout: "1" });
  assert.equal(hasOptedOut("sentiero_optout", fakeDoc(), storage), true);
});

test("hasOptedOut is false when both signals are absent", () => {
  assert.equal(hasOptedOut("sentiero_optout", fakeDoc(), fakeStorage()), false);
});

test("hasOptedOut treats falsy values as not opted out", () => {
  const doc = fakeDoc("sentiero_optout=0");
  assert.equal(hasOptedOut("sentiero_optout", doc, fakeStorage()), false);
});

test("hasOptedOut is false without a cookie name", () => {
  assert.equal(hasOptedOut("", fakeDoc("x=1"), fakeStorage({ x: "1" })), false);
});

test("optOut sets both the cookie and localStorage", () => {
  const doc = fakeDoc();
  const storage = fakeStorage();
  optOut("sentiero_optout", doc, storage);
  assert.match(doc.cookie, /sentiero_optout=1/);
  assert.equal(storage.getItem("sentiero_optout"), "1");
  assert.equal(hasOptedOut("sentiero_optout", doc, storage), true);
});

test("optIn clears both the cookie and localStorage", () => {
  const doc = fakeDoc("sentiero_optout=1");
  const storage = fakeStorage({ sentiero_optout: "1" });
  optIn("sentiero_optout", doc, storage);
  assert.equal(storage.getItem("sentiero_optout"), null);
  assert.equal(hasOptedOut("sentiero_optout", doc, storage), false);
});
