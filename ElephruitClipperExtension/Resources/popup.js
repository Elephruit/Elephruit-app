const state = { tab: null, page: null, mode: "article", busy: false };
const byID = (id) => document.getElementById(id);

async function activeTab() {
  const tabs = await browser.tabs.query({ active: true, currentWindow: true });
  return tabs[0];
}

async function extractPage(tabID) {
  try {
    return await browser.tabs.sendMessage(tabID, { type: "elephruit.extract" });
  } catch {
    // The tab may have been open before the extension was enabled or updated. Inject once so the
    // user does not have to reload; the guard in content.js makes this safe on already-prepared tabs.
    await browser.scripting.executeScript({ target: { tabId: tabID }, files: ["content.js"] });
    return browser.tabs.sendMessage(tabID, { type: "elephruit.extract" });
  }
}

function readableError(error) {
  if (typeof error === "string") return error;
  return error?.message || error?.localizedDescription || error?.description || "Safari denied access to this page.";
}

async function loadPage() {
  try {
    state.tab = await activeTab();
    if (!state.tab?.id || !/^https?:/i.test(state.tab.url || "")) throw new Error("Open an HTTP or HTTPS page and try again.");

    state.page = await extractPage(state.tab.id);
    if (!state.page) throw new Error("Safari couldn’t read this page.");

    byID("title").value = state.page.title;
    byID("source").textContent = `${state.page.siteName || new URL(state.page.sourceURL).hostname} · ${new URL(state.page.sourceURL).hostname}`;
    byID("site-letter").textContent = (state.page.siteName || new URL(state.page.sourceURL).hostname).slice(0, 1).toUpperCase();
    document.querySelector("[data-mode='selection']").disabled = !state.page.selection;
    const saved = await browser.storage.local.get(["elephruitClipMode", "elephruitClipTags"]);
    const preferred = saved.elephruitClipMode;
    selectMode(preferred === "selection" && !state.page.selection ? "article" : preferred || "article");
    byID("tags").value = saved.elephruitClipTags || "";
    byID("loading").hidden = true;
    byID("clip-form").hidden = false;
    byID("title").focus();
    byID("title").setSelectionRange(byID("title").value.length, byID("title").value.length);
  } catch (error) {
    const detail = readableError(error);
    showFatal(`${detail} In Safari Settings → Extensions → Elephruit Web Clipper, allow website access, then reload the page.`);
  }
}

function contentFor(mode) {
  if (!state.page) return { markdown: "", html: null, text: "" };
  if (mode === "selection") return state.page.selection || { markdown: "", html: null, text: "" };
  if (mode === "fullPage") return state.page.fullPage;
  if (mode === "article") return state.page.article;
  if (mode === "screenshot") return { markdown: state.page.excerpt || "Visible page screenshot", html: null, text: "A screenshot of the visible page will be attached." };
  return { markdown: "", html: null, text: state.page.excerpt || state.page.article.text.slice(0, 500) };
}

function selectMode(mode) {
  const button = document.querySelector(`[data-mode='${mode}']`);
  if (!button || button.disabled) return;
  state.mode = mode;
  document.querySelectorAll(".mode").forEach((item) => item.classList.toggle("active", item === button));
  const content = contentFor(mode);
  byID("preview").textContent = content.text || "This clip will keep the page title and original link.";
  const count = content.text?.length || 0;
  byID("preview-count").textContent = mode === "screenshot" ? "Visible area" : count ? `${count.toLocaleString()} characters` : "Link only";
}

function tagSlugs() {
  return byID("tags").value.split(/[,#]+/).map((value) => value.trim()).filter(Boolean);
}

async function screenshotData() {
  if (state.mode !== "screenshot") return null;
  return browser.tabs.captureVisibleTab(state.tab.windowId, { format: "png" });
}

async function save(event) {
  event.preventDefault();
  if (state.busy) return;
  state.busy = true;
  byID("save").disabled = true;
  byID("save").querySelector("span").textContent = "Saving…";
  setStatus("");

  try {
    const content = contentFor(state.mode);
    const tags = tagSlugs();
    const clip = {
      version: 1,
      id: crypto.randomUUID(),
      mode: state.mode,
      title: byID("title").value.trim(),
      sourceURL: state.page.sourceURL,
      canonicalURL: state.page.canonicalURL || null,
      siteName: state.page.siteName || null,
      author: state.page.author || null,
      excerpt: state.page.excerpt || null,
      contentMarkdown: content.markdown || "",
      contentHTML: ["article", "selection", "fullPage"].includes(state.mode) ? content.html : null,
      comment: byID("comment").value.trim(),
      tagSlugs: tags,
      projectHint: byID("project").value.trim() || null,
      screenshotData: await screenshotData(),
      clippedAt: new Date().toISOString()
    };

    const response = await browser.runtime.sendNativeMessage("com.elephruit.Elephruit", { action: "enqueueClip", clip });
    if (!response?.success) throw new Error(response?.error || "Elephruit didn’t accept the clip.");
    await browser.storage.local.set({ elephruitClipMode: state.mode, elephruitClipTags: byID("tags").value });
    setStatus(response.openedApp ? "Saved to Elephruit." : "Saved. Elephruit will import it when opened.", true);
    byID("save").querySelector("span").textContent = "Saved";
    setTimeout(() => window.close(), 900);
  } catch (error) {
    state.busy = false;
    byID("save").disabled = false;
    byID("save").querySelector("span").textContent = "Try again";
    setStatus(error.message || "The clip could not be saved.");
  }
}

function setStatus(message, success = false) {
  byID("status").textContent = message;
  byID("status").classList.toggle("success", success);
}

function showFatal(message) {
  byID("loading").hidden = true;
  byID("clip-form").hidden = true;
  byID("error").hidden = false;
  byID("error-message").textContent = message;
}

document.querySelectorAll(".mode").forEach((button) => button.addEventListener("click", () => selectMode(button.dataset.mode)));
byID("clip-form").addEventListener("submit", save);
document.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && event.metaKey) byID("clip-form").requestSubmit();
});
loadPage();
