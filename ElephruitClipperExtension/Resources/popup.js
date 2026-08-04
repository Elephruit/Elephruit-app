const title = document.getElementById("title");
const detail = document.getElementById("detail");
const spinner = document.getElementById("spinner");
const retry = document.getElementById("retry");
let accessRequest = null;

function readableError(error) {
  return error?.message || error?.localizedDescription || error?.description || String(error || "Safari denied access to this page.");
}

async function activeTab() {
  const tabs = await browser.tabs.query({ active: true, currentWindow: true });
  return tabs[0];
}

async function invokePanel(tabID) {
  const results = await browser.scripting.executeScript({
    target: { tabId: tabID },
    func: () => globalThis.__elephruitClipperAPI?.openPanel?.() || null
  });
  return results.find((result) => result.frameId === 0)?.result || results[0]?.result || null;
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function siteAccess(tab) {
  const url = new URL(tab.url);
  return {
    hostname: url.hostname.replace(/^www\./i, ""),
    pattern: `${url.protocol}//${url.host}/*`
  };
}

async function injectAndOpenPanel(tabID, milliseconds = 15_000) {
  const deadline = Date.now() + milliseconds;
  let lastError = null;

  while (Date.now() < deadline) {
    try {
      // The target defaults to the top frame. Retrying here handles pages that replace their main
      // document during redirects without sending messages to unrelated advertising frames.
      await browser.scripting.executeScript({
        target: { tabId: tabID },
        files: ["panel.js", "content.js"]
      });
      const response = await invokePanel(tabID);
      if (typeof response?.open === "boolean") return response;
      lastError = new Error("The clipper script loaded, but its page API was unavailable.");
    } catch (error) {
      lastError = error;
    }
    await delay(500);
  }

  throw new Error(`Safari could not attach the clipper to this page. ${readableError(lastError)}`);
}

function showAccessRequest(tab, site) {
  accessRequest = { tab, site };
  spinner.hidden = true;
  retry.hidden = false;
  retry.textContent = `Allow ${site.hostname}`;
  title.textContent = "Allow access to this website";
  detail.textContent = `Elephruit needs permission to read ${site.hostname} for this clip.`;
}

function showFailure(error) {
  accessRequest = null;
  spinner.hidden = true;
  retry.hidden = false;
  retry.textContent = "Try again";
  title.textContent = "Couldn’t open the clipper";
  const message = readableError(error);
  detail.textContent = /denied|permission|access/i.test(message)
    ? "Allow Elephruit on this website, then click Try again."
    : message;
}

async function openOnTab(tab) {
  let response = await invokePanel(tab.id).catch(() => null);
  if (typeof response?.open === "boolean") {
    window.close();
    return;
  }

  const site = siteAccess(tab);
  const allowed = await browser.permissions.contains({ origins: [site.pattern] });
  if (!allowed) {
    showAccessRequest(tab, site);
    return;
  }

  // Safari's persisted content-script registration can be unavailable in local development builds.
  // Inject into the approved top frame directly and retry through any provisional navigation.
  title.textContent = "Preparing the clipper…";
  detail.textContent = "Connecting securely to this page.";
  response = await injectAndOpenPanel(tab.id);

  if (typeof response?.open !== "boolean") {
    throw new Error("Safari did not attach the clipper to this page. Check website access, then try again.");
  }
  window.close();
}

async function togglePanel() {
  accessRequest = null;
  retry.hidden = true;
  retry.textContent = "Try again";
  spinner.hidden = false;
  title.textContent = "Opening Elephruit…";
  detail.textContent = "Preparing the clipper on this page.";

  try {
    const tab = await activeTab();
    if (!tab?.id || !/^https?:/i.test(tab.url || "")) {
      throw new Error("Open a regular website and try again.");
    }

    await openOnTab(tab);
  } catch (error) {
    showFailure(error);
  }
}

async function handleButton() {
  if (!accessRequest) {
    await togglePanel();
    return;
  }

  const request = accessRequest;
  spinner.hidden = false;
  retry.hidden = true;
  title.textContent = "Requesting website access…";
  detail.textContent = `Safari will ask whether Elephruit may read ${request.site.hostname}.`;

  try {
    const granted = await browser.permissions.request({ origins: [request.site.pattern] });
    if (!granted) throw new Error("Website access was not granted.");
    accessRequest = null;
    title.textContent = "Opening Elephruit…";
    detail.textContent = "Preparing the clipper on this page.";
    await openOnTab(request.tab);
  } catch (error) {
    showFailure(error);
  }
}

retry.addEventListener("click", handleButton);
togglePanel();
