const title = document.getElementById("title");
const detail = document.getElementById("detail");
const spinner = document.getElementById("spinner");
const retry = document.getElementById("retry");

function readableError(error) {
  return error?.message || error?.localizedDescription || error?.description || String(error || "Safari denied access to this page.");
}

function withTimeout(promise, milliseconds, message) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(message)), milliseconds);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

async function activeTab() {
  const tabs = await browser.tabs.query({ active: true, currentWindow: true });
  return tabs[0];
}

async function messagePanel(tabID) {
  return withTimeout(
    browser.tabs.sendMessage(tabID, { type: "elephruit.panel.toggle.v5" }),
    3_000,
    "Safari did not answer the clipper."
  );
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function waitForInjectedPanel(tabID, milliseconds) {
  const deadline = Date.now() + milliseconds;
  while (Date.now() < deadline) {
    const response = await messagePanel(tabID).catch(() => null);
    if (typeof response?.open === "boolean") return response;
    await delay(250);
  }
  return null;
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

    // Allowed pages normally already have the dormant content script. Messaging it is much faster
    // and more reliable on large pages than asking Safari to start a new script transaction.
    let response = await messagePanel(tab.id).catch(() => null);
    if (typeof response?.open !== "boolean") {
      // A tab opened before the extension was enabled or updated has no current isolated-world API.
      // Safari can leave the returned injection promise pending on continuously loading pages even
      // after it has executed the scripts. Start the guarded injection, then poll the listener that
      // proves the page is actually ready instead of trusting that completion promise.
      browser.scripting.executeScript({
        target: { tabId: tab.id },
        files: ["panel.js", "content.js"]
      }).catch(() => {});
      response = await waitForInjectedPanel(tab.id, 8_000);
    }

    if (typeof response?.open !== "boolean") {
      throw new Error("Safari took too long to prepare this page. Reload it once, then try again.");
    }
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
