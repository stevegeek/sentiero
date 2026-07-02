// Select-all / bulk actions
const selectAll = document.getElementById("select-all");
const checkboxes = document.querySelectorAll(".session-checkbox");
const bulkActions = document.getElementById("bulk-actions");
const selectedCount = document.getElementById("selected-count");
const bulkDeleteForm = document.getElementById("bulk-delete-form");

function updateUI() {
  const checked = document.querySelectorAll(".session-checkbox:checked").length;
  if (bulkActions) bulkActions.style.display = checked > 0 ? "block" : "none";
  if (selectedCount) selectedCount.textContent = checked;
  if (selectAll) selectAll.checked = checked === checkboxes.length && checkboxes.length > 0;
}

if (selectAll) {
  selectAll.addEventListener("change", () => {
    checkboxes.forEach((cb) => { cb.checked = selectAll.checked; });
    updateUI();
  });
}

checkboxes.forEach((cb) => {
  cb.addEventListener("change", updateUI);
});

if (bulkDeleteForm) {
  bulkDeleteForm.addEventListener("submit", (e) => {
    const msg = bulkDeleteForm.getAttribute("data-confirm");
    if (msg && !confirm(msg)) {
      e.preventDefault();
    }
  });
}

document.addEventListener("click", (e) => {
  const target = e.target.closest("[data-action='delete-session']");
  if (!target) return;

  if (!confirm("Delete this session?")) return;

  const sessionId = target.getAttribute("data-session-id");
  const csrfToken = target.getAttribute("data-csrf-token");
  const basePath = target.getAttribute("data-base-path");

  const form = document.createElement("form");
  form.method = "POST";
  form.action = `${basePath}/sessions/${sessionId}?_method=delete`;
  const input = document.createElement("input");
  input.type = "hidden";
  input.name = "csrf_token";
  input.value = csrfToken;
  form.appendChild(input);
  document.body.appendChild(form);
  form.submit();
});
