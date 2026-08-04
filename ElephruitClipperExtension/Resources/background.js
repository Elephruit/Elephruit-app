async function toggleClipperPanel(tab) {
  if (!tab?.id || !/^https?:/i.test(tab.url || "")) return;

  try {
    const response = await browser.tabs.sendMessage(tab.id, { type: "elephruit.panel.toggle.v1" });
    if (typeof response?.open === "boolean") return;
  } catch {
    // A tab open during an extension update may not have the newest content script yet.
  }

  await browser.scripting.executeScript({ target: { tabId: tab.id }, files: ["content.js"] });
  await browser.tabs.sendMessage(tab.id, { type: "elephruit.panel.toggle.v1" });
}

browser.action.onClicked.addListener((tab) => {
  toggleClipperPanel(tab).catch(() => {
    // Safari owns protected and internal pages; the extension cannot place UI on those tabs.
  });
});
