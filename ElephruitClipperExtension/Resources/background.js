async function toggleClipperPanel(tab) {
  if (!tab?.id || !/^https?:/i.test(tab.url || "")) return;

  try {
    const response = await browser.tabs.sendMessage(tab.id, { type: "elephruit.panel.open.v1" });
    if (typeof response?.open === "boolean") return;
  } catch {
    // A tab open during an extension update may not have the newest content script yet.
  }

  await browser.scripting.executeScript({ target: { tabId: tab.id }, files: ["panel.js", "content.js"] });
  await browser.tabs.sendMessage(tab.id, { type: "elephruit.panel.open.v1" });
}

function dataURL(buffer, mimeType) {
  const bytes = new Uint8Array(buffer);
  const chunks = [];
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    chunks.push(String.fromCharCode(...bytes.subarray(offset, offset + 0x8000)));
  }
  return `data:${mimeType};base64,${btoa(chunks.join(""))}`;
}

async function downloadImage(source) {
  const url = new URL(source);
  if (!["http:", "https:"].includes(url.protocol)) throw new Error("Unsupported image URL.");
  const response = await fetch(url.href, { credentials: "omit", cache: "force-cache" });
  if (!response.ok) throw new Error(`Image request failed with ${response.status}.`);
  const declaredLength = Number(response.headers.get("content-length") || 0);
  if (declaredLength > 6_000_000) throw new Error("Image is too large.");
  const blob = await response.blob();
  if (!blob.type.startsWith("image/") || blob.size > 6_000_000) throw new Error("Invalid image response.");
  return {
    data: dataURL(await blob.arrayBuffer(), blob.type),
    mimeType: blob.type,
    byteCount: blob.size
  };
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
  if (message?.type === "elephruit.image.download.v1") {
    return downloadImage(message.url);
  }
  if (message?.type === "elephruit.native.enqueue.v1") {
    return browser.runtime.sendNativeMessage("com.elephruit.Elephruit", {
      action: "enqueueClip",
      clip: message.clip
    });
  }
  return undefined;
});
