// Count the pages marked in each tab, on the toolbar badge.
const counts = new Map();

browser.runtime.onMessage.addListener((message, sender) => {
  if (message.type !== "marked" || !sender.tab) return;
  const count = (counts.get(sender.tab.id) ?? 0) + 1;
  counts.set(sender.tab.id, count);
  browser.action.setBadgeText({ tabId: sender.tab.id, text: String(count) });
});

browser.tabs.onRemoved.addListener((tabId) => counts.delete(tabId));

browser.runtime.onInstalled.addListener(() => {
  browser.contextMenus.create({ id: "marker-hello", title: "Say Hello from Marker", contexts: ["page"] });
});

browser.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === "marker-hello" && tab) {
    browser.tabs.update(tab.id, { url: "https://example.com/?hello=marker" });
  }
});
