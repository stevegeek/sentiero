const CANVAS_MAX_WIDTH = 720;

const GRADIENT = [
  { stop: 0.0, color: [37, 99, 235] }, // blue
  { stop: 0.5, color: [219, 39, 119] }, // pink
  { stop: 1.0, color: [234, 88, 12] }, // orange-red
];

function lerp(a, b, t) {
  return a + (b - a) * t;
}

export function densityColor(intensity) {
  const t = Math.max(0, Math.min(1, intensity));
  for (let i = 1; i < GRADIENT.length; i++) {
    const lo = GRADIENT[i - 1];
    const hi = GRADIENT[i];
    if (t <= hi.stop) {
      const local = (t - lo.stop) / (hi.stop - lo.stop || 1);
      return [
        Math.round(lerp(lo.color[0], hi.color[0], local)),
        Math.round(lerp(lo.color[1], hi.color[1], local)),
        Math.round(lerp(lo.color[2], hi.color[2], local)),
      ];
    }
  }
  return GRADIENT[GRADIENT.length - 1].color;
}

export async function fetchHeatmapData(jsonUrl, pageUrl) {
  const sep = jsonUrl.includes("?") ? "&" : "?";
  const res = await fetch(`${jsonUrl}${sep}url=${encodeURIComponent(pageUrl)}`, {
    headers: { Accept: "application/json" },
  });
  if (!res.ok) throw new Error(`heatmap request failed: ${res.status}`);
  return res.json();
}

export async function fetchViewportSize(eventsUrlTemplate, window) {
  if (!window) return null;
  const url = eventsUrlTemplate
    .replace("{session}", encodeURIComponent(window.session_id))
    .replace("{window}", encodeURIComponent(window.window_id));
  try {
    const res = await fetch(url, { headers: { Accept: "application/json" } });
    if (!res.ok) return null;
    const events = await res.json();
    for (const ev of events) {
      if (ev && ev.type === 4 && ev.data && ev.data.width && ev.data.height) {
        return { width: ev.data.width, height: ev.data.height };
      }
    }
  } catch {
    return null;
  }
  return null;
}

// Colour and alpha scale by each bucket's share of the peak count, so hot
// spots read clearly without one outlier washing out the rest.
export function renderHeatmapCanvas(canvas, data, viewport) {
  const gridSize = data.grid_size || 20;
  const aspect =
    viewport && viewport.width > 0 ? viewport.height / viewport.width : 1;
  const width = CANVAS_MAX_WIDTH;
  const height = Math.round(width * aspect);

  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext("2d");
  if (!ctx) return;

  ctx.clearRect(0, 0, width, height);

  const buckets = data.clicks_by_bucket || [];
  const peak = buckets.reduce((m, b) => Math.max(m, b.count), 0);
  if (peak === 0) return;

  const cellW = width / gridSize;
  const cellH = height / gridSize;

  for (const bucket of buckets) {
    const intensity = bucket.count / peak;
    const [r, g, b] = densityColor(intensity);
    ctx.fillStyle = `rgba(${r}, ${g}, ${b}, ${0.25 + intensity * 0.55})`;
    ctx.fillRect(bucket.x * cellW, bucket.y * cellH, cellW, cellH);
  }
}

export function renderTopElements(tbody, data) {
  const elements = data.top_elements || [];
  const total = data.total_clicks || 0;
  tbody.replaceChildren();

  if (elements.length === 0) {
    const row = document.createElement("tr");
    const cell = document.createElement("td");
    cell.className = "py-2 text-gray-400 text-center";
    cell.textContent = "No element data.";
    row.appendChild(cell);
    tbody.appendChild(row);
    return;
  }

  for (const el of elements) {
    const row = document.createElement("tr");
    row.className = "border-b border-gray-100 last:border-0";

    const selectorCell = document.createElement("td");
    selectorCell.className = "py-1 font-mono text-gray-700 truncate max-w-0 w-full";
    selectorCell.textContent = el.selector;

    const countCell = document.createElement("td");
    countCell.className = "py-1 pl-2 text-right text-gray-500 tabular-nums";
    const pct = total > 0 ? Math.round((el.count / total) * 100) : 0;
    countCell.textContent = `${el.count} (${pct}%)`;

    row.append(selectorCell, countCell);
    tbody.appendChild(row);
  }
}

async function load(config) {
  const status = document.getElementById("heatmap-status");
  const canvas = document.getElementById("heatmap-canvas");
  const tbody = document.getElementById("heatmap-top-elements");
  if (!config.selectedUrl || !canvas || !tbody) return;

  try {
    const data = await fetchHeatmapData(config.jsonUrl, config.selectedUrl);
    const viewport = await fetchViewportSize(
      config.eventsUrlTemplate,
      data.representative_window
    );
    renderHeatmapCanvas(canvas, data, viewport);
    renderTopElements(tbody, data);
    if (status) {
      status.textContent =
        data.total_clicks === 0
          ? "No clicks recorded for this page."
          : `${data.total_clicks} clicks aggregated.`;
    }
  } catch (err) {
    if (status) status.textContent = "Could not load heatmap data.";
  }
}

function init() {
  const configEl = document.getElementById("heatmap-config");
  if (!configEl) return;

  let config;
  try {
    config = JSON.parse(configEl.textContent);
  } catch {
    return;
  }

  const select = document.querySelector("[data-heatmap-url]");
  if (select && select.form) {
    select.addEventListener("change", () => select.form.submit());
    for (const input of select.form.querySelectorAll('input[type="date"]')) {
      input.addEventListener("change", () => select.form.submit());
    }
    const apply = document.querySelector("[data-heatmap-apply]");
    if (apply) apply.style.display = "none";
  }

  load(config);
}

init();
