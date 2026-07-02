import { test } from "node:test";
import assert from "node:assert/strict";

import { getEntryMetadata } from "../src/session_manager.js";

// Minimal Storage stand-in (a jar) matching the style of the other tests.
function fakeStorage(initial = {}) {
  const jar = new Map(Object.entries(initial));
  return {
    getItem: (k) => (jar.has(k) ? jar.get(k) : null),
    setItem: (k, v) => jar.set(k, String(v)),
    removeItem: (k) => jar.delete(k),
    _jar: jar,
  };
}

function withEnv({ href, referrer, localStorage, sessionStorage }, fn) {
  const g = globalThis;
  const saved = {
    location: Object.getOwnPropertyDescriptor(g, "location"),
    document: Object.getOwnPropertyDescriptor(g, "document"),
    localStorage: Object.getOwnPropertyDescriptor(g, "localStorage"),
    sessionStorage: Object.getOwnPropertyDescriptor(g, "sessionStorage"),
  };
  try {
    Object.defineProperty(g, "location", { value: { href }, configurable: true });
    Object.defineProperty(g, "document", { value: { referrer }, configurable: true });
    Object.defineProperty(g, "localStorage", { value: localStorage, configurable: true });
    Object.defineProperty(g, "sessionStorage", { value: sessionStorage, configurable: true });
    return fn();
  } finally {
    for (const [k, d] of Object.entries(saved)) {
      if (d) Object.defineProperty(g, k, d);
      else delete g[k];
    }
  }
}

test("captures entry url + referrer on first call", () => {
  const ls = fakeStorage();
  withEnv({ href: "https://ex.com/", referrer: "https://google.com/", localStorage: ls, sessionStorage: fakeStorage() }, () => {
    const m = getEntryMetadata(true);
    assert.equal(m.entry_url, "https://ex.com/");
    assert.equal(m.entry_referrer, "https://google.com/");
  });
});

test("is immutable across later pages of the same session", () => {
  const ls = fakeStorage();
  // First page of the session.
  withEnv({ href: "https://ex.com/", referrer: "https://google.com/", localStorage: ls, sessionStorage: fakeStorage() }, () => {
    getEntryMetadata(true);
  });
  // Second page: location/referrer changed, but entry data must NOT.
  withEnv({ href: "https://ex.com/app", referrer: "https://ex.com/signup", localStorage: ls, sessionStorage: fakeStorage() }, () => {
    const m = getEntryMetadata(true);
    assert.equal(m.entry_url, "https://ex.com/");
    assert.equal(m.entry_referrer, "https://google.com/");
  });
});

test("empty referrer is captured as empty string, not re-derived", () => {
  const ls = fakeStorage();
  withEnv({ href: "https://ex.com/", referrer: "", localStorage: ls, sessionStorage: fakeStorage() }, () => {
    assert.equal(getEntryMetadata(true).entry_referrer, "");
  });
  withEnv({ href: "https://ex.com/app", referrer: "https://elsewhere.com/", localStorage: ls, sessionStorage: fakeStorage() }, () => {
    // Still empty — the entry had no referrer; a later page's referrer cannot leak in.
    assert.equal(getEntryMetadata(true).entry_referrer, "");
  });
});

test("strips the query string and fragment from the entry url", () => {
  const ls = fakeStorage();
  withEnv({ href: "https://ex.com/signup?utm_source=abc&token=xyz#section", referrer: "", localStorage: ls, sessionStorage: fakeStorage() }, () => {
    const m = getEntryMetadata(true);
    assert.equal(m.entry_url, "https://ex.com/signup");
  });
});

test("strips the query string and fragment from the referrer too", () => {
  const ls = fakeStorage();
  withEnv({ href: "https://ex.com/", referrer: "https://ref.test/search?q=secret#top", localStorage: ls, sessionStorage: fakeStorage() }, () => {
    const m = getEntryMetadata(true);
    assert.equal(m.entry_referrer, "https://ref.test/search");
  });
});

test("a malformed/relative href still has its query and fragment stripped, not stored raw", () => {
  const ls = fakeStorage();
  withEnv({ href: "/relative/path?x=1#y", referrer: "", localStorage: ls, sessionStorage: fakeStorage() }, () => {
    const m = getEntryMetadata(true);
    assert.equal(m.entry_url, "/relative/path");
  });
});

test("returns {} when storage throws", () => {
  const throwing = {
    getItem() { throw new Error("blocked"); },
    setItem() { throw new Error("blocked"); },
  };
  withEnv({ href: "https://ex.com/", referrer: "", localStorage: throwing, sessionStorage: throwing }, () => {
    assert.deepEqual(getEntryMetadata(true), {});
  });
});
