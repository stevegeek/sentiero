// Shared redaction engine, twin of lib/sentiero/redaction.rb. Patterns and
// application order MUST match; test/fixtures/redaction_cases.json pins parity.

export const REDACTED = "[redacted]";
export const TEXT_PATTERN_ORDER = ["url", "jwt", "email", "long_hex", "card"];

const TEXT_PATTERNS = {
  jwt: /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g,
  email: /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g,
  long_hex: /\b[0-9a-fA-F]{32,}\b/g,
  card: /\b\d(?:[ -]?\d){12,18}\b/g,
};
const URL_IN_TEXT = /https?:\/\/\S+/g;

// Built-in secret param names always dropped in keepFiltered mode. Must match
// BUILTIN_DENYLIST in lib/sentiero/redaction.rb.
export const BUILTIN_DENYLIST = [
  "token", "access_token", "refresh_token", "id_token", "password", "passwd", "pwd", "secret",
  "api_key", "apikey", "key", "sig", "signature", "code", "auth", "session", "sessionid", "otp",
];

export function parseConfig(raw = {}) {
  return {
    urlMode: raw.urlMode || "strip",
    allowlist: (raw.urlParamAllowlist || []).map((s) => s.toLowerCase()),
    denylist: [...BUILTIN_DENYLIST, ...(raw.urlParamDenylist || []).map((s) => s.toLowerCase())],
    disabled: raw.disabledPatterns || [],
    // A pattern that is valid in Ruby but not JS must not throw out of init and
    // disable recording; skip the bad one and keep the rest.
    customRegexes: (raw.customPatterns || []).flatMap((s) => {
      try {
        return [new RegExp(s, "g")];
      } catch {
        console.warn(`[Sentiero] skipping invalid custom redaction pattern: ${s}`);
        return [];
      }
    }),
  };
}

function stripUrlString(url) {
  let cut = url.indexOf("?");
  const hash = url.indexOf("#");
  if (cut < 0) cut = url.length;
  if (hash >= 0 && hash < cut) cut = hash;
  return url.slice(0, cut);
}

function applyTextPattern(text, name) {
  if (name === "url") return text.replace(URL_IN_TEXT, (m) => stripUrlString(m));
  return text.replace(TEXT_PATTERNS[name], REDACTED);
}

export function redactText(value, cfg) {
  if (typeof value !== "string") return value;
  let out = value;
  for (const name of TEXT_PATTERN_ORDER) {
    if (!cfg.disabled.includes(name)) out = applyTextPattern(out, name);
  }
  for (const re of cfg.customRegexes) out = out.replace(re, REDACTED);
  return out;
}

function splitUrl(url) {
  let base = url;
  let frag = "";
  const h = base.indexOf("#");
  if (h >= 0) { frag = base.slice(h + 1); base = base.slice(0, h); }
  let query = "";
  const q = base.indexOf("?");
  if (q >= 0) { query = base.slice(q + 1); base = base.slice(0, q); }
  return { base, query, frag };
}

// Plain percent-decode (leaves "+" alone, unlike www-form decoding). Falls
// back to the raw value on a malformed escape rather than throwing, since
// this parses attacker-controlled URLs from public events.
function urlDecode(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

function filterParam(pair, cfg) {
  const eq = pair.indexOf("=");
  const name = (eq >= 0 ? pair.slice(0, eq) : pair).toLowerCase();
  // Denylist wins over the allowlist so allowlisting a built-in secret name
  // (token/password/...) can't re-enable persisting it.
  if (cfg.denylist.includes(name)) return null;
  if (cfg.allowlist.includes(name)) return pair;
  if (eq < 0) return pair;

  // Match patterns against the decoded value (email=user%40example.com must
  // be caught the same as email=user@example.com) but only substitute when
  // something actually matched; a clean survivor keeps its original,
  // unmodified encoding rather than being needlessly re-encoded.
  const rawValue = pair.slice(eq + 1);
  const decoded = urlDecode(rawValue);
  const redacted = redactText(decoded, cfg);
  return redacted === decoded ? pair : pair.slice(0, eq) + "=" + redacted;
}

export function redactUrl(url, cfg) {
  if (typeof url !== "string") return url;
  if (cfg.urlMode === "keepAll") return url;
  if (cfg.urlMode !== "keepFiltered") return stripUrlString(url);

  const { base, query, frag } = splitUrl(url);
  const pairs = query ? query.split("&").map((p) => filterParam(p, cfg)).filter((p) => p !== null) : [];
  let out = base;
  if (pairs.length) out += "?" + pairs.join("&");
  if (frag) out += "#" + redactText(frag, cfg);
  return out;
}

// Structural layer: which field of which side-channel event/metadata is a URL vs
// free text. MUST match lib/sentiero/redaction.rb (CUSTOM_FIELD_MAP / URL_METADATA_KEYS);
// the custom_event/metadata cases in redaction_cases.json pin that parity.
export const CUSTOM_EVENT_TYPE = 5;
export const META_EVENT_TYPE = 4;
export const URL_METADATA_KEYS = ["url", "referrer", "entry_url", "entry_referrer"];
export const CUSTOM_FIELD_MAP = {
  navigation: { url: "url", text: "text" },
  __form_submit: { url: "url" },
  error: { message: "text", stack: "text", source: "url" },
  __click: { selector: "text" },
};

export function deepRedactStrings(value, cfg) {
  if (typeof value === "string") return redactText(value, cfg);
  if (Array.isArray(value)) return value.map((v) => deepRedactStrings(v, cfg));
  if (value && typeof value === "object") {
    const out = {};
    // Keys can carry PII too (e.g. a caller using an email as an object key);
    // redact them the same as values. Last-write-wins on key collisions.
    for (const [k, v] of Object.entries(value)) out[deepRedactStrings(k, cfg)] = deepRedactStrings(v, cfg);
    return out;
  }
  return value;
}

export function redactPayload(tag, payload, cfg) {
  if (payload == null || typeof payload !== "object") return payload;
  const map = CUSTOM_FIELD_MAP[tag];
  const out = {};
  // Mapped fields use their url/text treatment; every other field (and every
  // field of an unmapped tag) is deep-redacted rather than passed through raw.
  for (const [k, v] of Object.entries(payload)) {
    if (map && map[k] === "url") out[k] = redactUrl(v, cfg);
    else if (map && map[k] === "text") out[k] = redactText(v, cfg);
    else out[k] = deepRedactStrings(v, cfg);
  }
  return out;
}

export function redactEvent(event, cfg) {
  if (event && event.type === CUSTOM_EVENT_TYPE && event.data && typeof event.data === "object") {
    return { ...event, data: { ...event.data, payload: redactPayload(event.data.tag, event.data.payload, cfg) } };
  }
  // rrweb Meta events carry the full page URL in data.href, which bypasses
  // rrweb's own input masking entirely; always URL-redact it like any other
  // structural URL field (navigation.url, error.source, ...).
  if (event && event.type === META_EVENT_TYPE && event.data && typeof event.data === "object" && "href" in event.data) {
    return { ...event, data: { ...event.data, href: redactUrl(event.data.href, cfg) } };
  }
  return event;
}

export function redactMetadata(metadata, cfg) {
  if (metadata == null || typeof metadata !== "object") return metadata;
  const out = {};
  for (const [k, v] of Object.entries(metadata)) {
    out[k] = URL_METADATA_KEYS.includes(k) ? redactUrl(v, cfg) : deepRedactStrings(v, cfg);
  }
  return out;
}
