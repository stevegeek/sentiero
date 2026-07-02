import { test } from "node:test";
import assert from "node:assert/strict";

import { Transport } from "../src/transport.js";
import { parseConfig } from "../src/redaction.js";

// Minimal Storage stand-in matching the style of the other transport tests.
function fakeStorage(initial = {}) {
  const jar = new Map(Object.entries(initial));
  return {
    getItem: (k) => (jar.has(k) ? jar.get(k) : null),
    setItem: (k, v) => jar.set(k, String(v)),
    removeItem: (k) => jar.delete(k),
  };
}

// Replace browser globals for the duration of fn, then restore them.
// transport.js accesses `window.location.href` / `window.innerWidth` (not
// `globalThis.location`), so we must also set `globalThis.window`.
function withEnv({ href, referrer, localStorage, sessionStorage }, fn) {
  const g = globalThis;
  const saved = {
    window: Object.getOwnPropertyDescriptor(g, "window"),
    location: Object.getOwnPropertyDescriptor(g, "location"),
    document: Object.getOwnPropertyDescriptor(g, "document"),
    navigator: Object.getOwnPropertyDescriptor(g, "navigator"),
    localStorage: Object.getOwnPropertyDescriptor(g, "localStorage"),
    sessionStorage: Object.getOwnPropertyDescriptor(g, "sessionStorage"),
  };
  const locationObj = { href, origin: new URL(href).origin };
  const windowObj = { location: locationObj, innerWidth: 1280, innerHeight: 720 };
  try {
    Object.defineProperty(g, "window", { value: windowObj, configurable: true, writable: true });
    Object.defineProperty(g, "location", { value: locationObj, configurable: true });
    Object.defineProperty(g, "document", { value: { referrer: referrer || "" }, configurable: true });
    Object.defineProperty(g, "navigator", { value: { userAgent: "test-ua" }, configurable: true });
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

test("_collectMetadata strips query strings from url and referrer", () => {
  const ls = fakeStorage();
  const ss = fakeStorage();
  withEnv({
    href: "https://app.test/dashboard?token=secret&user=alice",
    referrer: "https://search.test/q?q=password&src=web",
    localStorage: ls,
    sessionStorage: ss,
  }, () => {
    const redactionCfg = parseConfig({});
    const transport = new Transport({ eventsUrl: "https://events.test/e", captureMetadata: true, redactionCfg });
    const meta = transport._collectMetadata();
    assert.equal(meta.url, "https://app.test/dashboard", "url query stripped");
    assert.equal(meta.referrer, "https://search.test/q", "referrer query stripped");
  });
});

test("_collectMetadata strips query strings from entry_url and entry_referrer", () => {
  const ls = fakeStorage();
  const ss = fakeStorage();
  // First call records entry metadata into localStorage.
  withEnv({
    href: "https://app.test/landing?promo=abc123",
    referrer: "https://partner.test/ref?id=xyz",
    localStorage: ls,
    sessionStorage: ss,
  }, () => {
    const redactionCfg = parseConfig({});
    const transport = new Transport({ eventsUrl: "https://events.test/e", captureMetadata: true, redactionCfg });
    const meta = transport._collectMetadata();
    assert.notEqual(meta.entry_url, null, "expected entry_url to be recorded");
    assert.equal(meta.entry_url, "https://app.test/landing", "entry_url query stripped");
    assert.notEqual(meta.entry_referrer, null, "expected entry_referrer to be recorded");
    assert.equal(meta.entry_referrer, "https://partner.test/ref", "entry_referrer query stripped");
  });
});

test("_collectMetadata with no query strings leaves urls unchanged", () => {
  const ls = fakeStorage();
  const ss = fakeStorage();
  withEnv({
    href: "https://app.test/home",
    referrer: "https://other.test/page",
    localStorage: ls,
    sessionStorage: ss,
  }, () => {
    const redactionCfg = parseConfig({});
    const transport = new Transport({ eventsUrl: "https://events.test/e", captureMetadata: true, redactionCfg });
    const meta = transport._collectMetadata();
    assert.equal(meta.url, "https://app.test/home");
    assert.equal(meta.referrer, "https://other.test/page");
  });
});

// Regression: setMetadata() values used to be spread on top of already-
// redacted _collectMetadata() output, so they never passed through
// redactMetadata at all. _buildPayload must redact the merged result.
test("_buildPayload pattern-redacts custom metadata merged with collected metadata", () => {
  const ls = fakeStorage();
  const ss = fakeStorage();
  withEnv({
    href: "https://app.test/home",
    referrer: "",
    localStorage: ls,
    sessionStorage: ss,
  }, () => {
    const redactionCfg = parseConfig({});
    const transport = new Transport({ eventsUrl: "https://events.test/e", captureMetadata: true, redactionCfg });
    const payload = JSON.parse(transport._buildPayload([], { plan: "pro", note: "contact jane@example.com" }));
    assert.equal(payload.metadata.note, "contact [redacted]");
    assert.equal(payload.metadata.plan, "pro", "verbatim operator values survive unchanged");
  });
});

// Same regression, but for the branch taken when captureMetadata is off (or
// entry metadata already sent): customMetadata rode through completely
// unredacted before.
test("_buildPayload pattern-redacts custom-metadata-only payloads", () => {
  const ls = fakeStorage();
  const ss = fakeStorage();
  withEnv({
    href: "https://app.test/home",
    referrer: "",
    localStorage: ls,
    sessionStorage: ss,
  }, () => {
    const transport = new Transport({ eventsUrl: "https://events.test/e", redactionCfg: parseConfig({}) });
    const payload = JSON.parse(transport._buildPayload([], { note: "contact jane@example.com" }));
    assert.equal(payload.metadata.note, "contact [redacted]");
  });
});
