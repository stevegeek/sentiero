const select = document.querySelector("[data-analytics-range]");
if (select) {
  const form = select.form;
  const applyButton = document.querySelector("[data-analytics-apply]");
  const dateInputs = form
    ? Array.from(form.querySelectorAll('input[type="date"]'))
    : [];

  select.addEventListener("change", () => {
    for (const input of dateInputs) input.value = "";
    if (form) form.submit();
  });

  for (const input of dateInputs) {
    input.addEventListener("change", () => {
      if (form) form.submit();
    });
  }

  // With JS available the change handlers cover submission; hide the button.
  if (applyButton) applyButton.style.display = "none";
}
