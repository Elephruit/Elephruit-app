const title = document.getElementById("title");
const detail = document.getElementById("detail");
const spinner = document.getElementById("spinner");
const retry = document.getElementById("retry");

function readableError(error) {
  return error?.message || error?.localizedDescription || error?.description || String(error || "Safari denied access to this page.");
}

async function activeTab() {
  const tabs = await browser.tabs.query({ active: true, currentWindow: true });
  return tabs[0];
}

async function callNewestPanelAPI(tabID) {
  const results = await browser.scripting.executeScript({
    target: { tabId: tabID },
    func: () => {
      const api = globalThis.__elephruitClipperAPI;
      if (!api || api.version < 10 || typeof api.togglePanel !== "function") return null;
      return api.togglePanel();
    }
  });
  return results?.[0]?.result ?? null;
}

async function togglePanel() {
  retry.hidden = true;
  spinner.hidden = false;
  title.textContent = "Opening Elephruit…";
  detail.textContent = "Preparing the clipper on this page.";

  try {
    const tab = await activeTab();
    if (!tab?.id || !/^https?:/i.test(tab.url || "")) {
      throw new Error("Open a regular website and try again.");
    }

    let response = await callNewestPanelAPI(tab.id).catch(() => null);
    if (typeof response?.open !== "boolean") {
      // A tab opened before the extension was enabled or updated has no current isolated-world API.
      // Inject both halves explicitly; the scripts are guarded and therefore safe on prepared tabs.
      await browser.scripting.executeScript({
        target: { tabId: tab.id },
        files: ["panel.js", "content.js"]
      });
      response = await callNewestPanelAPI(tab.id);
    }

    if (typeof response?.open !== "boolean") throw new Error("Safari could not start the clipper on this page.");
    window.close();
  } catch (error) {
    spinner.hidden = true;
    retry.hidden = false;
    title.textContent = "Couldn’t open the clipper";
    const message = readableError(error);
    detail.textContent = /denied|permission|access/i.test(message)
      ? "Allow Elephruit on this website, then click Try again."
      : message;
  }
}

retry.addEventListener("click", togglePanel);
togglePanel();
