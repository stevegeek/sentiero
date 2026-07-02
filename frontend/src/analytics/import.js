const PLAYER_MOUNT_ID = "import-player";
const STATUS_ID = "import-status";
const TEXTAREA_ID = "import-textarea";
const FILE_INPUT_ID = "import-file";
const DROP_ZONE_ID = "import-dropzone";
const REPLAY_BUTTON_ID = "import-replay";

const MAX_FILE_BYTES = 25 * 1024 * 1024;

export function parseEventsJSON(text) {
  const trimmed = (text || "").trim();
  if (!trimmed) {
    return { ok: false, error: "Paste some JSON or choose a file first." };
  }

  let parsed;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return { ok: false, error: "That doesn't look like valid JSON." };
  }

  if (!Array.isArray(parsed)) {
    return { ok: false, error: "Expected a JSON array of events." };
  }

  return { ok: true, events: parsed };
}

export function validateEvents(events) {
  if (!Array.isArray(events)) {
    return { ok: false, error: "Expected a JSON array of events." };
  }
  if (events.length === 0) {
    return { ok: false, error: "The file contains no events." };
  }
  if (events.length < 2) {
    return { ok: false, error: "At least two events are needed to replay." };
  }

  for (const event of events) {
    if (!event || typeof event !== "object") {
      return { ok: false, error: "Every event must be an object." };
    }
    if (typeof event.type !== "number") {
      return { ok: false, error: "Every event needs a numeric type." };
    }
    if (typeof event.timestamp !== "number") {
      return { ok: false, error: "Every event needs a numeric timestamp." };
    }
  }

  return { ok: true };
}

function mountPlayer(container, events) {
  if (typeof rrwebPlayer === "undefined") {
    throw new Error("rrweb-player global not loaded");
  }
  // eslint-disable-next-line no-undef
  const Player = rrwebPlayer.default || rrwebPlayer;
  container.replaceChildren();
  return new Player({
    target: container,
    props: {
      events,
      width: container.clientWidth || 900,
      autoPlay: true,
      showController: true,
    },
  });
}

function setStatus(message, isError) {
  const status = document.getElementById(STATUS_ID);
  if (!status) return;
  status.textContent = message;
  status.classList.toggle("text-red-600", !!isError);
}

export function replayFromText(text, container) {
  const parsed = parseEventsJSON(text);
  if (!parsed.ok) {
    setStatus(parsed.error, true);
    return false;
  }

  const valid = validateEvents(parsed.events);
  if (!valid.ok) {
    setStatus(valid.error, true);
    return false;
  }

  try {
    mountPlayer(container, parsed.events);
  } catch {
    setStatus("Could not start the player.", true);
    return false;
  }

  setStatus(`Replaying ${parsed.events.length} events.`, false);
  return true;
}

function readFile(file, onText) {
  if (file.size > MAX_FILE_BYTES) {
    setStatus("That file is too large to import.", true);
    return;
  }
  const reader = new FileReader();
  reader.onload = () => onText(String(reader.result || ""));
  reader.onerror = () => setStatus("Could not read that file.", true);
  reader.readAsText(file);
}

function init() {
  const container = document.getElementById(PLAYER_MOUNT_ID);
  const textarea = document.getElementById(TEXTAREA_ID);
  const fileInput = document.getElementById(FILE_INPUT_ID);
  const dropZone = document.getElementById(DROP_ZONE_ID);
  const replayButton = document.getElementById(REPLAY_BUTTON_ID);
  if (!container) return;

  if (replayButton && textarea) {
    replayButton.addEventListener("click", () =>
      replayFromText(textarea.value, container)
    );
  }

  if (fileInput && textarea) {
    fileInput.addEventListener("change", () => {
      const file = fileInput.files && fileInput.files[0];
      if (file) {
        readFile(file, (text) => {
          textarea.value = text;
          replayFromText(text, container);
        });
      }
    });
  }

  if (dropZone && textarea) {
    dropZone.addEventListener("dragover", (event) => {
      event.preventDefault();
      dropZone.classList.add("border-blue-400");
    });
    dropZone.addEventListener("dragleave", () =>
      dropZone.classList.remove("border-blue-400")
    );
    dropZone.addEventListener("drop", (event) => {
      event.preventDefault();
      dropZone.classList.remove("border-blue-400");
      const file = event.dataTransfer && event.dataTransfer.files[0];
      if (file) {
        readFile(file, (text) => {
          textarea.value = text;
          replayFromText(text, container);
        });
      }
    });
  }
}

if (typeof document !== "undefined") {
  init();
}
