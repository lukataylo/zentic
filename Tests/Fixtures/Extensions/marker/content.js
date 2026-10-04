// Visible to the page and to Zentic's own world, which is how tests (and a
// person in the inspector) can tell the extension ran.
document.documentElement.dataset.markerExtension = "ran";
browser.runtime.sendMessage({ type: "marked" });
