import { record } from "rrweb";
import { mergePrivacyDefaults } from "./privacy.js";
import { Transport } from "./transport.js";
import { optOut, optIn } from "./opt_out.js";
import { shouldRecord } from "./config.js";
import { mirrorSessionCookies, clearSessionCookies } from "./session_cookie.js";
import { clearClientStorage } from "./session_manager.js";
import { setupFormSubmitTracking } from "./form_tracking.js";
import { redactUrl, redactPayload, parseConfig } from "./redaction.js";

function readConfig() {
  const configEl = document.getElementById("sentiero-config");
  if (configEl) {
    try {
      return JSON.parse(configEl.textContent);
    } catch (err) {
      console.warn("[Sentiero] failed to parse config element:", err);
    }
  }

  // Derive eventsUrl from the script's own URL.
  if (document.currentScript && document.currentScript.src) {
    const scriptUrl = new URL(document.currentScript.src);
    const pathParts = scriptUrl.pathname.split("/");
    pathParts[pathParts.length - 1] = "events";
    scriptUrl.pathname = pathParts.join("/");
    return { eventsUrl: scriptUrl.toString() };
  }

  console.warn("[Sentiero] no config found, recording disabled");
  return null;
}

export function navigationPayload({ href, text, external }, cfg) {
  const payload = { url: href };
  if (text) payload.text = text;
  if (external) payload.external = true;
  return redactPayload("navigation", payload, cfg);
}

export function errorPayload({ message, stack, source, ...rest }, cfg) {
  const payload = { ...rest, message, stack: stack || "" };
  if (source !== undefined) payload.source = source;
  return redactPayload("error", payload, cfg);
}

function setupErrorCapture(cfg) {
  window.addEventListener("error", (event) => {
    try {
      record.addCustomEvent("error", errorPayload({
        message: event.message || "Unknown error",
        source: event.filename || "",
        lineno: event.lineno || 0,
        colno: event.colno || 0,
        stack: event.error?.stack || "",
      }, cfg));
    } catch (e) {
      // Avoid infinite error loops
    }
  });

  window.addEventListener("unhandledrejection", (event) => {
    try {
      let message = "Unhandled Promise rejection";
      let stack = "";
      if (event.reason instanceof Error) {
        message = event.reason.message;
        stack = event.reason.stack || "";
      } else if (typeof event.reason === "string") {
        message = event.reason;
      }
      record.addCustomEvent("error", errorPayload({
        message: message,
        type: "unhandledrejection",
        stack: stack,
      }, cfg));
    } catch (e) {
      // Avoid infinite error loops
    }
  });
}

function setupWebVitals() {
  // Emits LCP/CLS/INP as rrweb custom events tagged "__perf" {metric, value, rating}.
  import("web-vitals")
    .then(({ onLCP, onCLS, onINP }) => {
      const emit = (metric) => {
        try {
          record.addCustomEvent("__perf", {
            metric: metric.name,
            value: metric.value,
            rating: metric.rating,
          });
        } catch (e) {
          // ignore
        }
      };
      onLCP(emit);
      onCLS(emit);
      onINP(emit);
    })
    .catch((e) => {
      console.warn("[Sentiero] web-vitals failed to load:", e);
    });
}

function setupNavigationTracking(cfg) {
  // Capture phase so the link click is recorded before navigation happens.
  document.addEventListener("click", (e) => {
    const link = e.target.closest("a[href]");
    if (!link) return;

    const href = link.href;
    if (!href || href.startsWith("javascript:") || href === "#") return;

    // Skip same-page anchors
    try {
      const target = new URL(href, window.location.href);
      if (target.origin === window.location.origin &&
          target.pathname === window.location.pathname &&
          target.hash) return;
    } catch { return; }

    const text = (link.textContent || "").trim().substring(0, 100);
    const isExternal = (() => {
      try {
        return new URL(href, window.location.href).origin !== window.location.origin;
      } catch { return false; }
    })();

    try {
      record.addCustomEvent("navigation", navigationPayload({ href, text, external: isExternal }, cfg));
    } catch (err) {
      // ignore
    }
  }, true);
}

// Compact, cross-session-stable selector (id, else tag + up to two classes).
// Walks up from text nodes / SVG glyphs to the nearest element so a click on a
// button's label resolves to the button.
function clickSelector(target) {
  let el = target;
  for (let depth = 0; el && depth < 3; depth++) {
    if (el.nodeType === 1 && el.tagName) break;
    el = el.parentElement;
  }
  if (!el || el.nodeType !== 1) return null;

  const tag = el.tagName.toLowerCase();
  if (el.id) return `${tag}#${el.id}`;

  const classes = (el.getAttribute("class") || "")
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2);
  return classes.length ? `${tag}.${classes.join(".")}` : tag;
}

// Annotate clicks with a stable selector for cross-session aggregation; rrweb's
// own click event only references an internal node id. Capture phase so it fires
// before any handler navigates away.
function setupClickCapture(cfg) {
  document.addEventListener(
    "click",
    (e) => {
      const selector = clickSelector(e.target);
      if (!selector) return;
      try {
        record.addCustomEvent("__click", redactPayload("__click", { selector }, cfg));
      } catch {
        // ignore
      }
    },
    true,
  );
}

const TRACKED_EVENTS = ["click", "change", "submit", "focus", "blur"];
const EVENT_NAME_PATTERN = /^[a-zA-Z0-9_.\-]{1,100}$/;
const MAX_DATA_LENGTH = 4096;

function setupCustomEventTracking(cfg) {
  for (const eventType of TRACKED_EVENTS) {
    document.addEventListener(
      eventType,
      (e) => {
        const attr = `data-sentiero-track-${eventType}`;
        const el = e.target.closest(`[${attr}]`);
        if (!el) return;

        const eventName = el.getAttribute(attr);
        if (!eventName || !EVENT_NAME_PATTERN.test(eventName)) return;

        let payload = {};
        const raw = el.getAttribute("data-sentiero-data");
        if (raw) {
          if (raw.length > MAX_DATA_LENGTH) return;
          try {
            payload = JSON.parse(raw);
          } catch {
            return;
          }
        }

        try {
          record.addCustomEvent(eventName, redactPayload(eventName, payload, cfg));
        } catch {
          // ignore
        }
      },
      true,
    );
  }
}

function init() {
  const config = readConfig();
  if (!config?.eventsUrl) {
    return;
  }

  const redactionCfg = parseConfig(config.redaction);

  const optOutCookieName = config.optOutCookieName;

  let transport = null;
  let stopRecording = null;

  window.Sentiero = window.Sentiero || {};
  window.Sentiero.optOut = () => {
    optOut(optOutCookieName);
    clearSessionCookies();
    // Leaving the identifier keys behind would let an opt-out -> opt-in cycle
    // silently resume the old session; the opt-out marker itself (set just
    // above) is untouched since it lives under a different key.
    clearClientStorage();
    if (stopRecording) {
      try {
        stopRecording();
      } catch {
        // ignore
      }
      stopRecording = null;
    }
    if (transport) {
      transport.discard();
      transport = null;
    }
  };
  window.Sentiero.optIn = () => optIn(optOutCookieName);

  // Bail before any transport or rrweb: an opted-out or GPC-signalling user
  // produces no events and makes no network requests.
  if (!shouldRecord(config)) {
    return;
  }

  transport = new Transport({
    eventsUrl: config.eventsUrl,
    flushIntervalMs: config.flushIntervalMs,
    flushEventThreshold: config.flushEventThreshold,
    crossTabSessions: config.crossTabSessions !== false,
    captureMetadata: config.captureMetadata === true,
    redactionCfg,
  });

  mirrorSessionCookies(transport.sessionId, transport.windowId);

  window.Sentiero.setMetadata = (data) => transport.setMetadata(data);
  window.Sentiero.addCustomEvent = (tag, payload) => {
    try {
      record.addCustomEvent(tag, redactPayload(tag, payload, redactionCfg));
    } catch (e) {
      console.warn("[Sentiero] addCustomEvent failed:", e);
    }
  };

  const mergedOptions = mergePrivacyDefaults(config.recorderOptions || {});

  try {
    stopRecording = record({
      ...mergedOptions,
      emit: (event) => transport.addEvent(event),
    });
  } catch (err) {
    console.error("[Sentiero] rrweb recording failed to start:", err);
    transport.stop();
    return;
  }

  if (config.captureErrors === true) {
    setupErrorCapture(redactionCfg);
  }

  if (config.trackNavigation === true) {
    setupNavigationTracking(redactionCfg);
  }

  if (config.trackCustomEvents === true) {
    setupCustomEventTracking(redactionCfg);
  }

  if (config.captureWebVitals === true) {
    setupWebVitals();
  }

  if (config.captureClicks === true) {
    setupClickCapture(redactionCfg);
  }

  if (config.trackForms === true) {
    setupFormSubmitTracking(
      document,
      (tag, payload) => record.addCustomEvent(tag, payload),
      () => redactUrl(window.location.href, redactionCfg),
    );
  }

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") {
      transport?.flushBeacon();
    }
  });

  document.addEventListener("pagehide", () => {
    transport?.flushBeacon();
  });

  transport.start();
}

if (typeof window !== "undefined") init();
