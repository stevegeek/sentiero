import test from "node:test";
import assert from "node:assert";
import { parseConfig } from "../src/redaction.js";
import { navigationPayload, errorPayload } from "../src/recorder.js";

test("navigation payload redacts url and text", () => {
  const p = navigationPayload({ href: "https://x.test/p?token=abc", text: "a@b.co", external: false }, parseConfig({}));
  assert.equal(p.url, "https://x.test/p");
  assert.equal(p.text, "[redacted]");
});

test("error payload redacts message and stack", () => {
  const p = errorPayload({ message: "fail a@b.co", stack: "at https://x.test/s?k=1" }, parseConfig({}));
  assert.equal(p.message, "fail [redacted]");
  assert.equal(p.stack, "at https://x.test/s");
});

test("error payload redacts source url, preserves lineno and type", () => {
  const p = errorPayload({ message: "oops", stack: "", source: "https://x.test/app.js?token=abc", lineno: 42, colno: 7, type: "unhandledrejection" }, parseConfig({}));
  assert.equal(p.source, "https://x.test/app.js");
  assert.equal(p.lineno, 42);
  assert.equal(p.type, "unhandledrejection");
});

test("error payload omits source field when not provided", () => {
  const p = errorPayload({ message: "oops", stack: "" }, parseConfig({}));
  assert.equal(Object.prototype.hasOwnProperty.call(p, "source"), false);
});
