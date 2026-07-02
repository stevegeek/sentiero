export function rowMatchesFilter(row, type, level) {
  if (type !== "all" && row.dataset.activityKind !== type) return false;
  if (level && row.dataset.activityLevel !== level) return false;
  return true;
}

export function initActivityFilter() {
  const container = document.getElementById("server-activity");
  if (!container) return;

  const rows = Array.from(container.querySelectorAll("[data-activity-row]"));
  if (rows.length === 0) return;

  const typeGroup = container.querySelector("[data-activity-filter-type]");
  const levelSelect = container.querySelector("[data-activity-filter-level]");

  if (!typeGroup && !levelSelect) return;

  let currentType = "all";
  let currentLevel = "";

  function applyFilter() {
    rows.forEach((row) => {
      const visible = rowMatchesFilter(row, currentType, currentLevel);
      row.style.display = visible ? "" : "none";
    });
  }

  if (typeGroup) {
    typeGroup.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-filter-type]");
      if (!btn) return;
      currentType = btn.dataset.filterType;
      Array.from(typeGroup.querySelectorAll("[data-filter-type]")).forEach((b) => {
        b.classList.toggle("btn-active", b === btn);
        b.classList.toggle("btn-secondary", b !== btn);
      });
      applyFilter();
    });
  }

  if (levelSelect) {
    levelSelect.addEventListener("change", () => {
      currentLevel = levelSelect.value;
      applyFilter();
    });
  }
}
