const PRIVACY_DEFAULTS = {
  maskAllInputs: true,
  maskInputOptions: { password: true },
  blockSelector: "[data-rr-block]",
  maskTextSelector: "[data-rr-mask]",
  ignoreSelector: "[data-rr-ignore]",
  sampling: { scroll: 150, input: "last" },
};

function shouldUnmask(element) {
  if (!element) return false;
  return element.closest?.("[data-sentiero-unmask]") !== null;
}

function isPasswordInput(element) {
  return !!element && element.tagName === "INPUT" && element.type === "password";
}

export function mergePrivacyDefaults(userOptions = {}) {
  const merged = { ...PRIVACY_DEFAULTS, ...userOptions };

  merged.maskInputOptions = {
    ...(userOptions.maskInputOptions || {}),
    password: true,
  };

  if (userOptions.sampling) {
    merged.sampling = { ...PRIVACY_DEFAULTS.sampling, ...userOptions.sampling };
  }

  // Per-element unmask for input values via maskInputFn. Password masking is
  // enforced first and cannot be disabled, even when the caller supplies their
  // own maskInputFn; their function still handles every non-password input.
  if (merged.maskAllInputs) {
    const userMaskInputFn = userOptions.maskInputFn;
    merged.maskInputFn = (text, element) => {
      if (merged.maskInputOptions.password && isPasswordInput(element)) {
        return "*".repeat(text.length);
      }
      if (userMaskInputFn) return userMaskInputFn(text, element);
      if (shouldUnmask(element)) return text;
      return "*".repeat(text.length);
    };
  }

  if (!merged.maskTextFn) {
    merged.maskTextFn = (text, element) => {
      if (shouldUnmask(element)) return text;
      return text.replace(/\S/g, "*");
    };
  }

  return merged;
}
