import { test } from "node:test";
import assert from "node:assert/strict";

import { mergePrivacyDefaults } from "../src/privacy.js";

// Minimal element stub. `unmask` controls whether closest() reports a
// data-sentiero-unmask ancestor (or self), mirroring the real DOM API.
function makeInput({ type = "text", unmask = false } = {}) {
  return {
    tagName: "INPUT",
    type,
    closest(selector) {
      return unmask && selector === "[data-sentiero-unmask]" ? this : null;
    },
  };
}

test("password input inside data-sentiero-unmask is still masked", () => {
  const { maskInputFn } = mergePrivacyDefaults();
  const el = makeInput({ type: "password", unmask: true });
  assert.equal(maskInputFn("hunter2", el), "*******");
});

test("password masking cannot be disabled via maskInputOptions", () => {
  const { maskInputFn } = mergePrivacyDefaults({
    maskInputOptions: { password: false },
  });
  const el = makeInput({ type: "password", unmask: true });
  assert.equal(maskInputFn("hunter2", el), "*******");
});

test("text input inside data-sentiero-unmask is unmasked", () => {
  const { maskInputFn } = mergePrivacyDefaults();
  const el = makeInput({ type: "text", unmask: true });
  assert.equal(maskInputFn("visible", el), "visible");
});

test("text input outside unmask region is masked", () => {
  const { maskInputFn } = mergePrivacyDefaults();
  const el = makeInput({ type: "text", unmask: false });
  assert.equal(maskInputFn("secret", el), "******");
});

test("custom maskInputFn cannot unmask a password input", () => {
  // A user fn that returns the raw text must still not leak passwords.
  const { maskInputFn } = mergePrivacyDefaults({
    maskInputFn: (text) => text,
  });
  const el = makeInput({ type: "password" });
  assert.equal(maskInputFn("hunter2", el), "*******");
});

test("custom maskInputFn is honored for non-password inputs", () => {
  const { maskInputFn } = mergePrivacyDefaults({
    maskInputFn: (text) => `redacted:${text.length}`,
  });
  const el = makeInput({ type: "text" });
  assert.equal(maskInputFn("secret", el), "redacted:6");
});
