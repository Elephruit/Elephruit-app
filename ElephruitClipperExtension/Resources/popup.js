const state = { tab: null, page: null, mode: "article", busy: false };
const byID = (id) => document.getElementById(id);

async function activeTab() {
  const tabs = await browser.tabs.query({ active: true, currentWindow: true });
  return tabs[0];
}

async function extractPage(tabID) {
  try {
    const page = await browser.tabs.sendMessage(tabID, { type: "elephruit.extract.v3" });
    if (page?.schemaVersion === 3) return page;
    throw new Error("This tab has an older page extractor.");
  } catch {
    // The tab may have been open before the extension was enabled or updated. Inject once so the
    // user does not have to reload; the guard in content.js makes this safe on already-prepared tabs.
    await browser.scripting.executeScript({ target: { tabId: tabID }, files: ["content.js"] });
    return browser.tabs.sendMessage(tabID, { type: "elephruit.extract.v3" });
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
  if (mode === "simplifiedArticle") return state.page.simplifiedArticle || state.page.article;
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
  const image = content.images?.[0] || state.page.article?.images?.[0];
  const previewImage = byID("preview-image");
  if (image?.url && mode !== "screenshot") {
    previewImage.src = image.url;
    previewImage.hidden = false;
  } else {
    previewImage.removeAttribute("src");
    previewImage.hidden = true;
  }
  const count = content.text?.length || 0;
  byID("preview-count").textContent = mode === "screenshot" ? "Visible area" : mode === "fullPage" ? "Page + searchable text" : count ? `${count.toLocaleString()} characters` : "Link + preview";
}

function tagSlugs() {
  return byID("tags").value.split(/[,#]+/).map((value) => value.trim()).filter(Boolean);
}

function dataURLFor(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(reader.error || new Error("An image could not be read."));
    reader.readAsDataURL(blob);
  });
}

function imageType(mime) {
  return {
    "image/png": { typeIdentifier: "public.png", extension: "png" },
    "image/jpeg": { typeIdentifier: "public.jpeg", extension: "jpg" },
    "image/gif": { typeIdentifier: "com.compuserve.gif", extension: "gif" },
    "image/webp": { typeIdentifier: "org.webmproject.webp", extension: "webp" }
  }[mime.toLowerCase()];
}

function inferredImageType(blob, url) {
  const declared = imageType(blob.type || "");
  if (declared) return declared;
  const extension = new URL(url).pathname.split(".").pop()?.toLowerCase();
  return {
    png: imageType("image/png"),
    jpg: imageType("image/jpeg"),
    jpeg: imageType("image/jpeg"),
    gif: imageType("image/gif"),
    webp: imageType("image/webp")
  }[extension];
}

async function capturedImages(content) {
  if (!["article", "simplifiedArticle", "selection"].includes(state.mode)) return [];
  const images = [];
  let total = 0;
  for (const candidate of (content.images || []).slice(0, 12)) {
    try {
      const response = await fetch(candidate.url, { credentials: "include", cache: "force-cache" });
      if (!response.ok) continue;
      const blob = await response.blob();
      const format = inferredImageType(blob, candidate.url);
      if (!format || blob.size > 6_000_000 || total + blob.size > 18_000_000) continue;
      total += blob.size;
      images.push({
        id: crypto.randomUUID(),
        sourceURL: candidate.url,
        altText: candidate.alt || "",
        filename: `web-image-${String(images.length + 1).padStart(2, "0")}.${format.extension}`,
        typeIdentifier: format.typeIdentifier,
        data: await dataURLFor(blob)
      });
    } catch {
      // A page may deny hotlinking one image. Keep the rest of the clip instead of failing it all.
    }
  }
  return images;
}

function loadedImage(source) {
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => resolve(image);
    image.onerror = () => reject(new Error("Safari could not compose the page capture."));
    image.src = source;
  });
}

async function fullPageImages() {
  const metrics = await browser.tabs.sendMessage(state.tab.id, { type: "elephruit.capture.start.v3" });
  const maximumCaptures = 32;
  const pageHeight = Math.min(metrics.pageHeight, metrics.viewportHeight * maximumCaptures);
  const positions = [];
  for (let y = 0; y < pageHeight; y += metrics.viewportHeight) positions.push(y);
  const last = Math.max(0, pageHeight - metrics.viewportHeight);
  if (positions.at(-1) !== last) positions.push(last);

  const captures = [];
  try {
    for (const y of positions) {
      const settled = await browser.tabs.sendMessage(state.tab.id, { type: "elephruit.capture.scroll.v3", y });
      const data = await browser.tabs.captureVisibleTab(state.tab.windowId, { format: "jpeg", quality: 90 });
      captures.push({ y: settled.scrollY, image: await loadedImage(data) });
    }
  } finally {
    await browser.tabs.sendMessage(state.tab.id, { type: "elephruit.capture.finish.v3" }).catch(() => {});
  }

  const pixelRatio = captures[0].image.width / metrics.viewportWidth;
  const maximumPanelPixels = 7_200;
  const panelHeight = Math.max(
    metrics.viewportHeight,
    Math.min(metrics.viewportHeight * 3, Math.floor(maximumPanelPixels / pixelRatio))
  );
  const panelCount = Math.ceil(pageHeight / panelHeight);
  const panels = [];

  for (let panelIndex = 0; panelIndex < panelCount; panelIndex += 1) {
    const panelTop = panelIndex * panelHeight;
    const panelBottom = Math.min(pageHeight, panelTop + panelHeight);
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(metrics.viewportWidth * pixelRatio));
    canvas.height = Math.max(1, Math.round((panelBottom - panelTop) * pixelRatio));
    const context = canvas.getContext("2d");

    for (const capture of captures) {
      const captureTop = capture.y;
      const captureBottom = capture.y + metrics.viewportHeight;
      const overlapTop = Math.max(panelTop, captureTop);
      const overlapBottom = Math.min(panelBottom, captureBottom);
      if (overlapBottom <= overlapTop) continue;

      const sourceY = Math.round((overlapTop - captureTop) * pixelRatio);
      const sourceHeight = Math.min(
        capture.image.height - sourceY,
        Math.round((overlapBottom - overlapTop) * pixelRatio)
      );
      const destinationY = Math.round((overlapTop - panelTop) * pixelRatio);
      context.drawImage(
        capture.image,
        0,
        sourceY,
        capture.image.width,
        sourceHeight,
        0,
        destinationY,
        canvas.width,
        sourceHeight
      );
    }

    let data = canvas.toDataURL("image/jpeg", 0.86);
    if (data.length > 8_000_000) data = canvas.toDataURL("image/jpeg", 0.68);
    if (data.length > 8_000_000) data = canvas.toDataURL("image/jpeg", 0.5);
    if (data.length > 8_000_000) data = canvas.toDataURL("image/jpeg", 0.35);
    panels.push({
      id: crypto.randomUUID(),
      sourceURL: null,
      altText: `Full-page capture ${panelIndex + 1} of ${panelCount}`,
      filename: `full-page-${String(panelIndex + 1).padStart(2, "0")}.jpg`,
      typeIdentifier: "public.jpeg",
      data
    });
  }
  return panels;
}

async function screenshotData() {
  if (!["screenshot", "bookmark"].includes(state.mode)) return null;
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
    setStatus(state.mode === "fullPage" ? "Capturing the full page…" : "Preserving the page…");
    const images = await capturedImages(content);
    if (state.mode === "fullPage") images.push(...await fullPageImages());
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
      contentHTML: ["article", "simplifiedArticle", "selection", "fullPage"].includes(state.mode) ? content.html : null,
      comment: byID("comment").value.trim(),
      tagSlugs: tags,
      projectHint: byID("project").value.trim() || null,
      images,
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
