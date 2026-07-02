import { getPlayerInstance, getLoadedEvents } from "./player.js";
import { toggleClickOverlay } from "./click_overlay.js";

export function copyLink() {
  const playerInstance = getPlayerInstance();
  const loadedEvents = getLoadedEvents();
  if (!playerInstance || loadedEvents.length === 0) return;
  try {
    const replayer = playerInstance.getReplayer();
    const current = replayer.getCurrentTime();
    const url = new URL(window.location.href);
    url.searchParams.set("t", Math.round(current));
    navigator.clipboard.writeText(url.toString()).then(() => {
      const btn = document.getElementById("copy-link-btn");
      if (btn) {
        const original = btn.textContent;
        btn.textContent = "Copied!";
        setTimeout(() => { btn.textContent = original; }, 2000);
      }
    });
  } catch (e) {
    console.warn("Sentiero: copy link failed", e);
  }
}

export function downloadJSON() {
  const loadedEvents = getLoadedEvents();
  if (loadedEvents.length === 0) return;
  try {
    const data = JSON.stringify(loadedEvents, null, 2);
    const blob = new Blob([data], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = "sentiero-session-events.json";
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  } catch (e) {
    console.warn("Sentiero: download failed", e);
  }
}

export function initToolbarActions() {
  document.addEventListener("click", (e) => {
    const target = e.target.closest("[data-action]");
    if (!target) return;

    const action = target.getAttribute("data-action");
    if (action === "copy-link") {
      copyLink();
    } else if (action === "toggle-clicks") {
      toggleClickOverlay();
    } else if (action === "download-json") {
      downloadJSON();
    } else if (action === "confirm-delete") {
      const message = target.getAttribute("data-confirm") || "Are you sure?";
      if (!confirm(message)) {
        e.preventDefault();
      }
    }
  });
}
