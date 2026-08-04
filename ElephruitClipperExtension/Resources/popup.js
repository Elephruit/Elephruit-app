const title = document.getElementById("title");
const detail = document.getElementById("detail");
const spinner = document.getElementById("spinner");
const retry = document.getElementById("retry");
let accessRequest = null;

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
    browser.tabs.sendMessage(tabID, { type: "elephruit.panel.open.v1" }),
    700,
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
    await delay(500);
  }
  return null;
}

function siteAccess(tab) {
  const url = new URL(tab.url);
  return {
    hostname: url.hostname.replace(/^www\./i, ""),
    pattern: `${url.protocol}//${url.host}/*`
  };
}

function contentScriptID(pattern) {
  let hash = 2166136261;
  for (const character of pattern) {
    hash ^= character.charCodeAt(0);
    hash = Math.imul(hash, 16777619);
  }
  return `elephruit-site-${(hash >>> 0).toString(16)}`;
}

async function ensureContentScript(site) {
  const id = contentScriptID(site.pattern);
  const scripts = await browser.scripting.getRegisteredContentScripts();
  if (scripts.some((script) => script.id === id)) return;
  await browser.scripting.registerContentScripts([{
    id,
    matches: [site.pattern],
    js: ["panel.js", "content.js"],
    runAt: "document_start",
    persistAcrossSessions: true
  }]);
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
  let response = await messagePanel(tab.id).catch(() => null);
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

  await ensureContentScript(site);

  // Direct execution is unreliable while a site is redirecting or its main document is still
  // provisional. Register the content script for this approved site, reload once, and let Safari
  // install it at document_start instead of racing the navigation.
  title.textContent = "Preparing the clipper…";
  detail.textContent = "Reloading this page once to finish website access.";
  await browser.tabs.reload(tab.id);
  await delay(500);
  response = await waitForInjectedPanel(tab.id, 15_000);

  if (typeof response?.open !== "boolean") {
    throw new Error("Safari did not load the clipper after reloading this page. Check website access, then try again.");
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
