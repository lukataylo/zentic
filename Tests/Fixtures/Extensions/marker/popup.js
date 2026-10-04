browser.tabs.query({ active: true, currentWindow: true }).then(([tab]) => {
  document.getElementById("tab").textContent = tab ? `On “${tab.title}”` : "No tab";
});
