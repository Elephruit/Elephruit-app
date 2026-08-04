async function toggleClipperPanel(tab) {
  if (!tab?.id || !/^https?:/i.test(tab.url || "")) return;

  try {
    const response = await browser.tabs.sendMessage(tab.id, { type: "elephruit.panel.toggle.v2" });
    if (typeof response?.open === "boolean") return;
  } catch {
    // A tab open during an extension update may not have the newest content script yet.
  }

  await browser.scripting.executeScript({ target: { tabId: tab.id }, files: ["content.js", "panel.js"] });
  await browser.tabs.sendMessage(tab.id, { type: "elephruit.panel.toggle.v2" });
}

browser.action.onClicked.addListener((tab) => {
  toggleClipperPanel(tab).catch(() => {
    // Safari owns protected and internal pages; the extension cannot place UI on those tabs.
  });
});

browser.runtime.onMessage.addListener((message, sender) => {
  if (message?.type === "elephruit.capture.visible.v1" && sender.tab?.windowId != null) {
    return browser.tabs.captureVisibleTab(sender.tab.windowId, message.options || { format: "png" });
  }
  if (message?.type === "elephruit.native.enqueue.v1") {
    return browser.runtime.sendNativeMessage("com.elephruit.Elephruit", {
      action: "enqueueClip",
      clip: message.clip
    });
  }
  return undefined;
});
