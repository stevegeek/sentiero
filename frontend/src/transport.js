import { gzipSync } from "fflate";
import { getSessionId, getWindowId, getEntryMetadata } from "./session_manager.js";
import { redactMetadata, redactEvent, parseConfig } from "./redaction.js";

const BEACON_MAX_BYTES = 64_000;

export class Transport {
  constructor({ eventsUrl, flushIntervalMs = 10000, flushEventThreshold = 50, maxBufferSize = 5000, crossTabSessions = true, captureMetadata = false, redactionCfg = null }) {
    this.eventsUrl = eventsUrl;
    this.flushIntervalMs = flushIntervalMs;
    this.flushEventThreshold = flushEventThreshold;
    this.maxBufferSize = maxBufferSize;
    this.buffer = [];
    this._stopped = false;
    this._crossTabSessions = crossTabSessions;
    this.sessionId = getSessionId(crossTabSessions);
    this.windowId = getWindowId();
    this._intervalId = null;
    this._flushing = false;
    this._retryCount = 0;
    this._maxRetries = 10;
    this._baseBackoffMs = 1000;
    this._maxBackoffMs = 30_000;
    this._lastFailureTime = null;
    this._captureMetadata = captureMetadata;
    this._metadataSent = false;
    this._customMetadata = {};
    this._redactionCfg = redactionCfg || parseConfig({});
  }

  start() {
    this._intervalId = setInterval(() => this.flush(), this.flushIntervalMs);
  }

  setMetadata(data) {
    if (data && typeof data === "object") {
      Object.assign(this._customMetadata, data);
    }
  }

  // Every event passes through here exactly once (both flush and beacon send
  // from this buffer), so this is the single seam to catch rrweb event types
  // that carry raw PII outside the custom-event/addCustomEvent path (e.g.
  // Meta events' data.href) - see redactEvent in redaction.js.
  addEvent(event) {
    this.buffer.push(redactEvent(event, this._redactionCfg));
    if (this.buffer.length > this.maxBufferSize) {
      const dropped = this.buffer.length - this.maxBufferSize;
      this.buffer.splice(0, dropped);
      console.warn(`[Sentiero] buffer overflow, dropped ${dropped} oldest events`);
    }
    if (this.buffer.length >= this.flushEventThreshold) {
      this.flush();
    }
  }

  _collectMetadata() {
    const meta = {};
    try {
      meta.url = window.location.href;
      meta.referrer = document.referrer || "";
      meta.userAgent = navigator.userAgent;
      meta.viewport = `${window.innerWidth}x${window.innerHeight}`;
      // Immutable entry url/referrer (first page of the session) so multi-page
      // sessions report where they truly arrived, not the latest navigation.
      Object.assign(meta, getEntryMetadata(this._crossTabSessions));
    } catch (e) {
      // ignore,  some fields may be unavailable
    }
    // redactMetadata redacts the URL_METADATA_KEYS (url/referrer/entry_*) and
    // leaves everything else, matching the server's redact_metadata.
    return redactMetadata(meta, this._redactionCfg);
  }

  // customMetadata is passed in (captured and cleared by the caller) so it
  // rides exactly one payload; entry metadata is attached once per session.
  _buildPayload(events, customMetadata) {
    const payload = {
      sessionId: this.sessionId,
      windowId: this.windowId,
      events,
    };

    if (this._captureMetadata && !this._metadataSent) {
      // The merged result (not just _collectMetadata()'s own fields) is run
      // through redactMetadata again so operator-supplied setMetadata()
      // values get the same pattern redaction as the browser-collected
      // fields, rather than riding through untouched; redacting the
      // already-redacted url/referrer a second time is a no-op.
      payload.metadata = redactMetadata({ ...this._collectMetadata(), ...customMetadata }, this._redactionCfg);
      this._metadataSent = true;
    } else if (Object.keys(customMetadata).length > 0) {
      payload.metadata = redactMetadata({ ...customMetadata }, this._redactionCfg);
    }

    return JSON.stringify(payload);
  }

  _handleFlushFailure(events, customMetadata, message, detail) {
    this._flushing = false;
    this._retryCount++;
    this._lastFailureTime = Date.now();
    console.warn(message, detail);
    this.buffer = events.concat(this.buffer);
    // Re-queue the events and the custom metadata that rode with them, and
    // reset metadataSent so entry metadata is re-sent on the next flush.
    this._customMetadata = { ...customMetadata, ...this._customMetadata };
    this._metadataSent = false;
  }

  flush() {
    if (this._stopped) return;
    if (this.buffer.length === 0) return;
    if (this._flushing) return;

    if (this._retryCount > 0) {
      const backoffMs = Math.min(this._baseBackoffMs * 2 ** (this._retryCount - 1), this._maxBackoffMs);
      if (!this._lastFailureTime || (Date.now() - this._lastFailureTime) < backoffMs) {
        return;
      }
    }

    if (this._retryCount >= this._maxRetries) {
      console.warn(`[Sentiero] max retries (${this._maxRetries}) exceeded, dropping ${this.buffer.length} events`);
      this.buffer.length = 0;
      this._retryCount = 0;
      this._lastFailureTime = null;
      return;
    }

    const events = this.buffer;
    this.buffer = [];
    const customMetadata = this._customMetadata;
    this._customMetadata = {};
    this._flushing = true;

    const payload = this._buildPayload(events, customMetadata);

    try {
      const compressed = gzipSync(new TextEncoder().encode(payload));

      fetch(this.eventsUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Content-Encoding": "gzip",
        },
        body: compressed,
      })
      .then(response => {
        this._flushing = false;
        if (response.ok) {
          this._retryCount = 0;
          this._lastFailureTime = null;
        } else {
          this._handleFlushFailure(events, customMetadata, "[Sentiero] server rejected events:", response.status);
        }
      })
      .catch((err) => {
        this._handleFlushFailure(events, customMetadata, "[Sentiero] flush failed, re-queuing events:", err);
      });
    } catch (err) {
      this._handleFlushFailure(events, customMetadata, "[Sentiero] compression failed, re-queuing events:", err);
    }
  }

  flushBeacon() {
    if (this._stopped) return;
    if (this.buffer.length === 0) return;

    const events = this.buffer;
    this.buffer = [];
    const customMetadata = this._customMetadata;
    this._customMetadata = {};
    this._sendBeaconChunk(events, customMetadata);
  }

  // Recursively halves an over-sized batch so ALL events are delivered on
  // unload, not just the first half. Metadata rides the first chunk only.
  _sendBeaconChunk(events, customMetadata) {
    if (events.length === 0) return;

    const payload = this._buildPayload(events, customMetadata);
    let blob;
    try {
      blob = new Blob([payload], { type: "application/json" });
    } catch (err) {
      console.warn("[Sentiero] beacon failed:", err);
      return;
    }

    if (blob.size > BEACON_MAX_BYTES && events.length > 1) {
      const half = Math.floor(events.length / 2);
      this._sendBeaconChunk(events.slice(0, half), customMetadata);
      this._sendBeaconChunk(events.slice(half), {});
      return;
    }

    if (!navigator.sendBeacon(this.eventsUrl, blob)) {
      console.warn("[Sentiero] sendBeacon rejected, events may be lost");
    }
  }

  stop() {
    if (this._intervalId !== null) {
      clearInterval(this._intervalId);
      this._intervalId = null;
    }
    this.flushBeacon();
  }

  // Opt-out mid-session: drop buffered events without sending; data captured
  // before opt-out must not leave the browser. The _stopped guard also
  // neutralizes any in-flight flush's re-queue retry.
  discard() {
    this._stopped = true;
    if (this._intervalId !== null) {
      clearInterval(this._intervalId);
      this._intervalId = null;
    }
    this.buffer.length = 0;
  }
}
