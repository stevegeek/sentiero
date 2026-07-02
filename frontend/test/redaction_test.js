import test from "node:test";
import assert from "node:assert";
import { readFileSync } from "node:fs";
import { redactText, redactUrl, redactEvent, redactMetadata, parseConfig } from "../src/redaction.js";

const CASES = JSON.parse(
  readFileSync(new URL("../../test/fixtures/redaction_cases.json", import.meta.url)),
);

test("email redacted", () => {
  assert.equal(redactText("User alice@example.com x", parseConfig({})), "User [redacted] x");
});

test("url in text keeps path", () => {
  assert.equal(redactText("go https://x.test/p?t=1#f end", parseConfig({})), "go https://x.test/p end");
});

test("non-string passthrough", () => {
  assert.equal(redactText(42, parseConfig({})), 42);
});

test("corpus text cases", () => {
  for (const c of CASES.filter((c) => c.op === "text")) {
    assert.equal(redactText(c.input, parseConfig(c.config)), c.expected, c.name);
  }
});

test("url strip default", () => {
  assert.equal(redactUrl("https://x.test/s?q=secret#f", parseConfig({})), "https://x.test/s");
});

test("corpus url cases", () => {
  for (const c of CASES.filter((c) => c.op === "url")) {
    assert.equal(redactUrl(c.input, parseConfig(c.config)), c.expected, c.name);
  }
});

test("corpus covers all url modes", () => {
  const modes = new Set(CASES.filter((c) => c.op === "url").map((c) => (c.config && c.config.urlMode) || "strip"));
  for (const m of ["strip", "keepAll", "keepFiltered"]) assert.ok(modes.has(m), `missing ${m}`);
});

test("corpus custom_event cases", () => {
  for (const c of CASES.filter((c) => c.op === "custom_event")) {
    assert.deepEqual(redactEvent(c.input, parseConfig(c.config)), c.expected, c.name);
  }
});

test("corpus metadata cases", () => {
  for (const c of CASES.filter((c) => c.op === "metadata")) {
    assert.deepEqual(redactMetadata(c.input, parseConfig(c.config)), c.expected, c.name);
  }
});

// Regression: rrweb Meta events (type 4) carry the full page URL in
// data.href, unshielded by rrweb's own input masking; it must be
// URL-redacted like any other structural URL field.
test("redactEvent strips meta event href by default", () => {
  const event = { type: 4, data: { href: "https://x.test/reset?token=s&email=u@e.com", width: 800, height: 600 } };
  const out = redactEvent(event, parseConfig({}));
  assert.equal(out.data.href, "https://x.test/reset");
  assert.equal(out.data.width, 800);
  assert.equal(out.data.height, 600);
});

test("redactEvent keep_filtered on meta event href", () => {
  const cfg = parseConfig({ urlMode: "keepFiltered", urlParamDenylist: ["token"] });
  const event = { type: 4, data: { href: "https://x.test/reset?token=s&email=u@e.com" } };
  const out = redactEvent(event, cfg);
  assert.equal(out.data.href, "https://x.test/reset?email=[redacted]");
});

test("redactEvent leaves non-meta non-custom events untouched", () => {
  const event = { type: 2, data: { href: "https://x.test/reset?token=s" } };
  assert.deepEqual(redactEvent(event, parseConfig({})), event);
});

// Regression: an invalid custom pattern (valid in Ruby, not JS) must not throw
// out of parseConfig and disable recording; it is skipped, the rest kept.
test("parseConfig skips an invalid custom pattern instead of throwing", () => {
  let cfg;
  assert.doesNotThrow(() => {
    cfg = parseConfig({ customPatterns: ["(unbalanced", "ACCT-\\d{6}"] });
  });
  assert.equal(cfg.customRegexes.length, 1);
  assert.equal(redactText("ref ACCT-123456 end", cfg), "ref [redacted] end");
});
