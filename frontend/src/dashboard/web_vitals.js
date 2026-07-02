import { TYPE_CUSTOM } from "./utils.js";

const METRIC_ORDER = ["LCP", "CLS", "INP"];

// Web Vitals from "__perf" rrweb custom events, keeping the last value per
// metric. Returns { LCP: {value, rating}, ... }.
export function extractWebVitals(events) {
  const vitals = Object.create(null);
  if (!Array.isArray(events)) return vitals;
  for (const event of events) {
    if (
      event &&
      event.type === TYPE_CUSTOM &&
      event.data &&
      event.data.tag === "__perf" &&
      event.data.payload
    ) {
      const p = event.data.payload;
      if (typeof p.metric === "string" && typeof p.value === "number") {
        vitals[p.metric] = { value: p.value, rating: p.rating };
      }
    }
  }
  return vitals;
}

export function formatVitalValue(metric, value) {
  if (metric === "CLS") {
    return value.toFixed(3);
  }
  return `${Math.round(value)} ms`;
}

function ratingClass(rating) {
  if (rating === "good") return "badge-success";
  if (rating === "needs-improvement") return "badge-warning";
  if (rating === "poor") return "badge-danger";
  return "badge-neutral";
}

export function renderWebVitalBadges(events, container) {
  if (!container) return;
  const vitals = extractWebVitals(events);
  container.innerHTML = "";

  let any = false;
  for (const metric of METRIC_ORDER) {
    const v = vitals[metric];
    if (!v) continue;
    any = true;
    const badge = document.createElement("span");
    badge.className = `badge ${ratingClass(v.rating)} shrink-0`;
    badge.textContent = `${metric} ${formatVitalValue(metric, v.value)}`;
    if (v.rating) badge.title = v.rating;
    container.appendChild(badge);
  }

  container.style.display = any ? "inline-flex" : "none";
}
