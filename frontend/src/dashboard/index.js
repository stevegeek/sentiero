import { initPlayer } from "./player.js";
import { copyLink, downloadJSON, initToolbarActions } from "./toolbar.js";
import { fetchAllEvents, adaptServerMarkers } from "./events.js";
import { stopPlaybackTracking } from "./sidebar.js";
import { toggleClickOverlay } from "./click_overlay.js";
import { computeScrollDepth } from "./scroll-depth.js";
import { detectFrustrationEvents } from "./frustration.js";
import { analyzeFormInteractions, buildFormContext } from "./form-interaction.js";
import { initActivityFilter } from "./activity_filter.js";

window.SentieroDashboard = {
  initPlayer,
  fetchAllEvents,
  copyLink,
  downloadJSON,
  toggleClickOverlay,
  computeScrollDepth,
  detectFrustrationEvents,
  analyzeFormInteractions,
  buildFormContext,
};

function parseServerMarkers() {
  const el = document.getElementById("server-activity-markers");
  if (!el) return [];
  try {
    return adaptServerMarkers(JSON.parse(el.textContent));
  } catch (e) {
    console.warn("Sentiero: failed to parse server-activity markers", e);
    return [];
  }
}

document.addEventListener("DOMContentLoaded", () => {
  const configEl = document.getElementById("sentiero-player-config");
  if (configEl) {
    try {
      const config = JSON.parse(configEl.textContent);
      const container = document.getElementById("replayer");
      if (config.eventsUrl && container) {
        const serverMarkers = parseServerMarkers();
        initPlayer(config.eventsUrl, container, serverMarkers);
      }
    } catch (e) {
      console.error("Sentiero: failed to parse player config", e);
    }
  }

  initToolbarActions();
  initActivityFilter();

  window.addEventListener("pagehide", stopPlaybackTracking);
});
