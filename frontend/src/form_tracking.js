// Form-analytics annotations (config: track_forms / trackForms).
//
// rrweb input events carry only an internal node id — no field names, no
// submit signal. This module emits those missing halves as custom events.
// __form_submit uses a capture-phase document `submit` listener so the
// FormAnalyzer counts real submits instead of inferring them from post-input
// navigations.
//
// Payloads are built from declared attributes only, never field values, so
// input masking guarantees are untouched.

export const FORM_SUBMIT_TAG = "__form_submit";

// Non-PII form identity: declared name/id attributes only.
export function formIdentity(form) {
  if (!form || typeof form.getAttribute !== "function") return {};

  const identity = {};
  const name = form.getAttribute("name");
  const id = form.getAttribute("id");
  if (name) identity.name = name;
  if (id) identity.id = id;
  return identity;
}

export function formSubmitPayload(form, url) {
  return { ...formIdentity(form), url };
}

export function setupFormSubmitTracking(doc, emit, getUrl) {
  doc.addEventListener(
    "submit",
    (e) => {
      const form = e.target;
      if (!form || typeof form.getAttribute !== "function") return;
      try {
        emit(FORM_SUBMIT_TAG, formSubmitPayload(form, getUrl()));
      } catch {
        // Never break the host page
      }
    },
    true,
  );
}
