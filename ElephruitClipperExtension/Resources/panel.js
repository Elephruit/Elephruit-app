(() => {
  if ((globalThis.__elephruitClipperPanelVersion || 0) >= 3) return;
  globalThis.__elephruitClipperPanelVersion = 3;

  let activeCleanup = null;
  let activeApplyBoundary = null;

  const markup = `
    <aside class="panel" role="dialog" aria-label="Elephruit Web Clipper">
      <header class="brandbar">
        <div class="brand"><span class="brand-icon">E</span><span>Elephruit</span></div>
        <div class="brand-actions">
          <span class="local-badge"><i></i> Local</span>
          <button id="close-panel" class="close-panel" type="button" aria-label="Close Elephruit Web Clipper" title="Close">×</button>
        </div>
      </header>

      <section id="loading" class="loading-state">
        <div class="spinner"></div>
        <p>Reading this page…</p>
      </section>

      <form id="clip-form" hidden>
        <section class="page-card">
          <div class="favicon" id="site-letter">E</div>
          <div class="page-copy">
            <input id="title" class="title-input" aria-label="Clip title" maxlength="500">
            <div id="source" class="source-line"></div>
          </div>
        </section>

        <fieldset>
          <legend>Clip format</legend>
          <div class="mode-grid">
            <button type="button" class="mode active" data-mode="article"><span>▤</span>Article</button>
            <button type="button" class="mode" data-mode="simplifiedArticle"><span>☰</span>Simplified</button>
            <button type="button" class="mode" data-mode="selection"><span>◩</span>Selection</button>
            <button type="button" class="mode" data-mode="fullPage"><span>▥</span>Full page</button>
            <button type="button" class="mode" data-mode="bookmark"><span>↗</span>Bookmark</button>
            <button type="button" class="mode" data-mode="screenshot"><span>⌗</span>Screenshot</button>
          </div>
        </fieldset>

        <section id="article-boundary" class="article-boundary" hidden>
          <button id="article-narrow" type="button" aria-label="Narrow article boundary" title="Narrow article boundary">−</button>
          <div>
            <strong id="article-boundary-count">Best article boundary</strong>
            <span id="article-boundary-detail">Green outline shows what will be clipped</span>
          </div>
          <button id="article-expand" type="button" aria-label="Expand article boundary" title="Expand article boundary">+</button>
        </section>

        <section class="preview-card" aria-live="polite">
          <div class="preview-label"><span>Preview</span><span id="preview-count"></span></div>
          <div class="preview-content">
            <img id="preview-image" class="preview-image" alt="" hidden>
            <div id="preview" class="preview-copy"></div>
          </div>
        </section>

        <label class="field">
          <span>Add a note</span>
          <textarea id="comment" rows="2" maxlength="4000" placeholder="Why are you keeping this?"></textarea>
        </label>

        <div class="field-row">
          <label class="field"><span>Tags</span><input id="tags" placeholder="research, design"></label>
          <label class="field"><span>File under</span><input id="project" placeholder="Inbox"></label>
        </div>

        <div id="status" class="status" role="status"></div>
        <button id="save" class="save-button" type="submit"><span>Save clip</span><kbd>⌘↵</kbd></button>
      </form>

      <section id="error" class="error-state" hidden>
        <div class="error-icon">!</div>
        <h1>This page can’t be clipped</h1>
        <p id="error-message">Open a regular web page and try again.</p>
      </section>
    </aside>`;

  const styles = `
    :host { all: initial; color-scheme: light dark; }
    *, *::before, *::after { box-sizing: border-box; }
    [hidden] { display: none !important; }
    .panel {
      --ink: #1e231f; --muted: #687069; --line: rgba(34,48,38,.13); --surface: #fff;
      --soft: #f4f6f2; --accent: #3d6f4b; --accent-soft: #e8f1e8; --danger: #a64135;
      position: fixed; top: 12px; right: 12px; width: min(390px, calc(100vw - 24px));
      max-height: calc(100vh - 24px); overflow: auto; overscroll-behavior: contain; pointer-events: auto;
      border: 1px solid rgba(28,43,32,.16); border-radius: 14px; background: var(--surface); color: var(--ink);
      box-shadow: 0 14px 48px rgba(0,0,0,.28); font: 13px/1.35 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      isolation: isolate; scrollbar-width: thin;
    }
    button, input, textarea { font: inherit; }
    .brandbar { position: sticky; top: 0; z-index: 2; display: flex; align-items: center; justify-content: space-between;
      height: 54px; padding: 0 16px; border-bottom: 1px solid var(--line); border-radius: 14px 14px 0 0;
      background: linear-gradient(180deg,#fbfcfa,#f6f8f5); }
    .brand { display: flex; align-items: center; gap: 9px; font-size: 15px; font-weight: 700; letter-spacing: -.2px; }
    .brand-icon { display: grid; width: 27px; height: 27px; place-items: center; border-radius: 7px;
      background: #dff0e1; color: #347044; font-size: 14px; font-weight: 800; box-shadow: 0 1px 3px rgba(25,45,31,.15); }
    .brand-actions { display: flex; align-items: center; gap: 10px; }
    .local-badge { display: flex; align-items: center; gap: 6px; color: var(--muted); font-size: 11px; font-weight: 600; }
    .local-badge i { width: 7px; height: 7px; border-radius: 99px; background: #4f9b61; box-shadow: 0 0 0 3px rgba(79,155,97,.12); }
    .close-panel { display: grid; width: 27px; height: 27px; padding: 0 0 2px; place-items: center; border: 1px solid var(--line);
      border-radius: 7px; background: var(--surface); color: var(--muted); font-size: 21px; line-height: 24px; cursor: pointer; }
    .close-panel:hover { border-color: rgba(61,111,75,.45); background: var(--accent-soft); color: var(--accent); }
    form { padding: 15px 16px 16px; }
    .page-card { display: flex; gap: 10px; min-width: 0; margin-bottom: 15px; }
    .favicon { flex: 0 0 35px; height: 35px; display: grid; place-items: center; border-radius: 9px; background: var(--accent-soft);
      color: var(--accent); font-size: 16px; font-weight: 750; }
    .page-copy { min-width: 0; flex: 1; }
    .title-input { width: 100%; padding: 0; border: 0; outline: 0; background: transparent; color: var(--ink);
      font-size: 14px; font-weight: 650; line-height: 19px; text-overflow: ellipsis; }
    .title-input:focus { box-shadow: 0 2px 0 var(--accent); }
    .source-line { overflow: hidden; color: var(--muted); font-size: 11px; line-height: 16px; text-overflow: ellipsis; white-space: nowrap; }
    fieldset { min-width: 0; margin: 0 0 14px; padding: 0; border: 0; }
    legend, .field > span { display: block; margin-bottom: 7px; color: #4c544d; font-size: 11px; font-weight: 650; letter-spacing: .01em; }
    .mode-grid { display: grid; grid-template-columns: repeat(3,1fr); gap: 5px; }
    .mode { min-width: 0; height: 49px; padding: 5px 2px; border: 1px solid var(--line); border-radius: 9px; background: var(--soft);
      color: #555e56; font-size: 9.5px; line-height: 12px; cursor: pointer; }
    .mode span { display: block; margin-bottom: 3px; font-size: 18px; line-height: 18px; }
    .mode:hover { border-color: rgba(61,111,75,.4); background: #f0f5ef; }
    .mode.active { border-color: rgba(61,111,75,.65); background: var(--accent-soft); color: #285c38; box-shadow: inset 0 0 0 1px rgba(61,111,75,.12); }
    .mode:disabled { opacity: .38; cursor: not-allowed; }
    .article-boundary { display: grid; grid-template-columns: 34px 1fr 34px; align-items: center; gap: 9px; margin: -4px 0 13px;
      padding: 8px; border: 1px solid rgba(61,111,75,.28); border-radius: 10px; background: var(--accent-soft); }
    .article-boundary div { min-width: 0; }
    .article-boundary strong, .article-boundary span { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .article-boundary strong { color: #285c38; font-size: 11px; line-height: 15px; }
    .article-boundary span { color: var(--muted); font-size: 9.5px; line-height: 14px; }
    .article-boundary button { width: 34px; height: 30px; padding: 0; border: 1px solid rgba(61,111,75,.35); border-radius: 7px;
      background: var(--surface); color: var(--accent); font-size: 20px; font-weight: 650; line-height: 27px; cursor: pointer; }
    .article-boundary button:hover:not(:disabled) { border-color: var(--accent); background: #f6faf5; }
    .article-boundary button:disabled { opacity: .28; cursor: default; }
    .preview-card { height: 116px; margin-bottom: 13px; padding: 10px 11px; overflow: hidden; border: 1px solid var(--line);
      border-radius: 10px; background: #fafbf9; }
    .preview-label { display: flex; justify-content: space-between; margin-bottom: 6px; color: #788078; font-size: 9.5px;
      font-weight: 700; letter-spacing: .08em; text-transform: uppercase; }
    .preview-content { display: flex; align-items: flex-start; gap: 9px; min-width: 0; }
    .preview-image { flex: 0 0 76px; width: 76px; height: 72px; border-radius: 7px; background: var(--soft); object-fit: cover; }
    .preview-copy { display: -webkit-box; overflow: hidden; color: #424943; font: 11.5px/17px ui-serif, Georgia, serif;
      white-space: pre-wrap; -webkit-box-orient: vertical; -webkit-line-clamp: 4; }
    .field { display: block; margin-bottom: 11px; }
    .field input, .field textarea { width: 100%; border: 1px solid var(--line); border-radius: 8px; outline: 0; background: var(--surface); color: var(--ink); }
    .field input { height: 33px; padding: 0 9px; }
    .field textarea { display: block; padding: 8px 9px; resize: none; line-height: 16px; }
    .field input:focus, .field textarea:focus { border-color: rgba(61,111,75,.7); box-shadow: 0 0 0 3px rgba(61,111,75,.1); }
    .field-row { display: grid; grid-template-columns: 1fr 1fr; gap: 9px; }
    .status { min-height: 17px; margin: -2px 1px 4px; color: var(--danger); font-size: 11px; line-height: 15px; }
    .status.success { color: var(--accent); }
    .save-button { display: flex; align-items: center; justify-content: space-between; width: 100%; height: 39px; padding: 0 12px 0 15px;
      border: 0; border-radius: 9px; background: var(--accent); color: white; font-weight: 680; cursor: pointer; box-shadow: 0 2px 6px rgba(39,87,53,.2); }
    .save-button:hover { background: #345f40; }
    .save-button:disabled { opacity: .65; cursor: wait; }
    kbd { padding: 2px 5px; border: 1px solid rgba(255,255,255,.25); border-radius: 4px; background: rgba(255,255,255,.11);
      color: rgba(255,255,255,.85); font-family: inherit; font-size: 10px; }
    .loading-state, .error-state { min-height: 480px; display: grid; align-content: center; justify-items: center; padding: 35px; color: var(--muted); text-align: center; }
    .spinner { width: 24px; height: 24px; border: 2px solid var(--line); border-top-color: var(--accent); border-radius: 50%; animation: spin .8s linear infinite; }
    .loading-state p { margin-top: 12px; }
    .error-icon { width: 34px; height: 34px; display: grid; place-items: center; border-radius: 50%; background: #f7e7e4; color: var(--danger); font-weight: 800; }
    .error-state h1 { margin: 12px 0 6px; color: var(--ink); font-size: 15px; }
    .error-state p { max-width: 280px; margin: 0; line-height: 18px; }
    @keyframes spin { to { transform: rotate(360deg); } }
    @media (prefers-color-scheme: dark) {
      .panel { --ink:#edf0ec; --muted:#9ca39c; --line:rgba(230,240,232,.14); --surface:#202420; --soft:#292e29; --accent:#609d70; --accent-soft:#293c2d; }
      .brandbar { background: linear-gradient(180deg,#292d29,#242824); }
      .mode:hover, .preview-card { background:#272c27; }
      .mode.active, .article-boundary strong { color:#a9d7b3; }
      .article-boundary button:hover:not(:disabled) { background:#314336; }
      .field > span, legend { color:#b5bcb5; }
      .preview-copy { color:#d1d5d1; }
    }`;

  function readableError(error) {
    if (typeof error === "string") return error;
    return error?.message || error?.localizedDescription || error?.description || "Safari denied access to this page.";
  }

  function withTimeout(promise, milliseconds, message) {
    let timer;
    const timeout = new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(message)), milliseconds);
    });
    return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
  }

  function mount(shadow, api) {
    activeCleanup?.();
    const style = document.createElement("style");
    style.textContent = styles;
    const shell = document.createElement("div");
    shell.innerHTML = markup;
    shadow.append(style, shell);

    const state = { page: null, mode: "article", busy: false, boundaryPromise: Promise.resolve(), disposed: false };
    const byID = (id) => shadow.getElementById(id);
    const listen = (target, event, handler, options) => {
      target.addEventListener(event, handler, options);
      return () => target.removeEventListener(event, handler, options);
    };
    const cleaners = [];

    function contentFor(mode) {
      if (!state.page) return { markdown: "", html: null, text: "" };
      if (mode === "selection") return state.page.selection || { markdown: "", html: null, text: "" };
      if (mode === "fullPage") return state.page.fullPage;
      if (mode === "article") return state.page.article;
      if (mode === "simplifiedArticle") return state.page.simplifiedArticle || state.page.article;
      if (mode === "screenshot") return { markdown: state.page.excerpt || "Visible page screenshot", html: null, text: "A screenshot of the visible page will be attached." };
      return { markdown: "", html: null, text: state.page.excerpt || state.page.article.text.slice(0, 500) };
    }

    function renderPreview(mode) {
      const content = contentFor(mode);
      byID("preview").textContent = content.text || "This clip will keep the page title and original link.";
      const image = content.images?.[0] || state.page?.article?.images?.[0];
      const previewImage = byID("preview-image");
      if (image?.url && mode !== "screenshot") {
        previewImage.src = image.url;
        previewImage.hidden = false;
      } else {
        previewImage.removeAttribute("src");
        previewImage.hidden = true;
      }
      const count = content.text?.length || 0;
      byID("preview-count").textContent = mode === "screenshot"
        ? "Visible area"
        : mode === "fullPage"
          ? "Page + searchable text"
          : count ? `${count.toLocaleString()} characters` : "Link + preview";
    }

    function applyArticleBoundary(payload) {
      if (!payload?.article || state.disposed) return;
      state.page.article = payload.article;
      state.page.simplifiedArticle = payload.simplifiedArticle || payload.article;
      const boundary = payload.boundary || {};
      byID("article-boundary-count").textContent = boundary.levelCount > 1
        ? `Boundary ${boundary.level || 1} of ${boundary.levelCount}`
        : "Best article boundary";
      byID("article-narrow").disabled = !boundary.canNarrow;
      byID("article-expand").disabled = !boundary.canExpand;
      byID("article-boundary-detail").textContent = `${Number(boundary.characterCount || 0).toLocaleString()} characters selected`;
      if (["article", "simplifiedArticle"].includes(state.mode)) renderPreview(state.mode);
    }
    activeApplyBoundary = applyArticleBoundary;

    async function syncArticleBoundary(mode) {
      const showsBoundary = ["article", "simplifiedArticle"].includes(mode);
      byID("article-boundary").hidden = !showsBoundary;
      if (showsBoundary) applyArticleBoundary(await Promise.resolve(api.showArticleSelection()));
      else await Promise.resolve(api.hideArticleSelection()).catch(() => {});
    }

    async function selectMode(mode) {
      const button = shadow.querySelector(`[data-mode='${mode}']`);
      if (!button || button.disabled || state.disposed) return;
      state.mode = mode;
      shadow.querySelectorAll(".mode").forEach((item) => item.classList.toggle("active", item === button));
      renderPreview(mode);
      const operation = syncArticleBoundary(mode);
      state.boundaryPromise = operation;
      await operation;
    }

    async function adjustArticleBoundary(delta) {
      if (state.busy || state.disposed) return;
      byID("article-narrow").disabled = true;
      byID("article-expand").disabled = true;
      const operation = Promise.resolve(api.adjustArticleSelection(delta)).then(applyArticleBoundary);
      state.boundaryPromise = operation;
      await operation;
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
      let extension = "";
      try { extension = new URL(url).pathname.split(".").pop()?.toLowerCase() || ""; } catch { return null; }
      return { png: imageType("image/png"), jpg: imageType("image/jpeg"), jpeg: imageType("image/jpeg"), gif: imageType("image/gif"), webp: imageType("image/webp") }[extension];
    }

    async function capturedImages(content) {
      if (!["article", "simplifiedArticle", "selection"].includes(state.mode)) return [];
      const images = [];
      let total = 0;
      for (const candidate of (content.images || []).slice(0, 12)) {
        try {
          const downloaded = await browser.runtime.sendMessage({
            type: "elephruit.image.download.v1",
            url: candidate.url
          });
          if (!downloaded?.data || !downloaded?.mimeType || !downloaded?.byteCount) continue;
          const format = inferredImageType({ type: downloaded.mimeType }, candidate.url);
          if (!format || downloaded.byteCount > 6_000_000 || total + downloaded.byteCount > 18_000_000) continue;
          total += downloaded.byteCount;
          images.push({
            id: crypto.randomUUID(), sourceURL: candidate.url, altText: candidate.alt || "",
            filename: `web-image-${String(images.length + 1).padStart(2, "0")}.${format.extension}`,
            typeIdentifier: format.typeIdentifier, data: downloaded.data
          });
        } catch {
          // Keep the rest of the clip when a page denies access to one image.
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

    async function captureVisible(options) {
      const response = await browser.runtime.sendMessage({ type: "elephruit.capture.visible.v1", options });
      if (typeof response !== "string" || !response.startsWith("data:")) throw new Error("Safari could not capture this page.");
      return response;
    }

    async function fullPageImages() {
      const metrics = await Promise.resolve(api.beginCapture());
      const maximumCaptures = 32;
      const pageHeight = Math.min(metrics.pageHeight, metrics.viewportHeight * maximumCaptures);
      const positions = [];
      for (let y = 0; y < pageHeight; y += metrics.viewportHeight) positions.push(y);
      const last = Math.max(0, pageHeight - metrics.viewportHeight);
      if (positions.at(-1) !== last) positions.push(last);

      const captures = [];
      try {
        for (const y of positions) {
          const settled = await Promise.resolve(api.scrollCapture(y));
          const data = await captureVisible({ format: "jpeg", quality: 90 });
          captures.push({ y: settled.scrollY, image: await loadedImage(data) });
        }
      } finally {
        await Promise.resolve(api.finishCapture()).catch(() => {});
      }
      if (!captures.length) return [];

      const pixelRatio = captures[0].image.width / metrics.viewportWidth;
      const maximumPanelPixels = 7_200;
      const panelHeight = Math.max(metrics.viewportHeight, Math.min(metrics.viewportHeight * 3, Math.floor(maximumPanelPixels / pixelRatio)));
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
          const overlapTop = Math.max(panelTop, capture.y);
          const overlapBottom = Math.min(panelBottom, capture.y + metrics.viewportHeight);
          if (overlapBottom <= overlapTop) continue;
          const sourceY = Math.round((overlapTop - capture.y) * pixelRatio);
          const sourceHeight = Math.min(capture.image.height - sourceY, Math.round((overlapBottom - overlapTop) * pixelRatio));
          const destinationY = Math.round((overlapTop - panelTop) * pixelRatio);
          context.drawImage(capture.image, 0, sourceY, capture.image.width, sourceHeight, 0, destinationY, canvas.width, sourceHeight);
        }

        let data = canvas.toDataURL("image/jpeg", .86);
        for (const quality of [.68, .5, .35]) {
          if (data.length <= 8_000_000) break;
          data = canvas.toDataURL("image/jpeg", quality);
        }
        panels.push({
          id: crypto.randomUUID(), sourceURL: null, altText: "",
          filename: `full-page-${String(panelIndex + 1).padStart(2, "0")}.jpg`, typeIdentifier: "public.jpeg", data
        });
      }
      return panels;
    }

    async function screenshotData() {
      if (!["screenshot", "bookmark"].includes(state.mode)) return null;
      return captureVisible({ format: "png" });
    }

    function localizedHTML(html, images, sourceURL) {
      if (!html) return null;
      const template = document.createElement("template");
      template.innerHTML = html;
      const imagesBySource = new Map();
      for (const image of images) {
        if (!image.sourceURL) continue;
        try {
          imagesBySource.set(new URL(image.sourceURL, sourceURL).href, image);
        } catch {
          // An invalid image URL cannot be preserved safely.
        }
      }

      template.content.querySelectorAll("img").forEach((element) => {
        let source = null;
        try {
          source = new URL(element.getAttribute("src"), sourceURL).href;
        } catch {
          // Missing and malformed sources are removed below.
        }
        const image = source ? imagesBySource.get(source) : null;
        if (image) element.setAttribute("src", `elephruit-attachment://${image.id}`);
        else element.remove();
        element.removeAttribute("srcset");
      });
      return template.innerHTML;
    }

    function setStatus(message, success = false) {
      if (state.disposed) return;
      byID("status").textContent = message;
      byID("status").classList.toggle("success", success);
    }

    function showFatal(message) {
      if (state.disposed) return;
      byID("loading").hidden = true;
      byID("clip-form").hidden = true;
      byID("error").hidden = false;
      byID("error-message").textContent = message;
      shadow.querySelector(".panel").scrollTop = 0;
    }

    async function save(event) {
      event.preventDefault();
      if (state.busy || state.disposed) return;
      state.busy = true;
      byID("save").disabled = true;
      byID("save").querySelector("span").textContent = "Saving…";
      setStatus("");

      try {
        await state.boundaryPromise;
        const content = contentFor(state.mode);
        const tags = tagSlugs();
        setStatus(state.mode === "fullPage" ? "Capturing the full page…" : "Preserving the page…");
        const images = await capturedImages(content);
        if (state.mode === "fullPage") images.push(...await fullPageImages());
        const clip = {
          version: 1, id: crypto.randomUUID(), mode: state.mode, title: byID("title").value.trim(),
          sourceURL: state.page.sourceURL, canonicalURL: state.page.canonicalURL || null, siteName: state.page.siteName || null,
          author: state.page.author || null, excerpt: state.page.excerpt || null, contentMarkdown: content.markdown || "",
          contentHTML: ["article", "simplifiedArticle", "selection", "fullPage"].includes(state.mode)
            ? localizedHTML(content.html, images, state.page.sourceURL)
            : null,
          comment: byID("comment").value.trim(), tagSlugs: tags, projectHint: byID("project").value.trim() || null,
          images, screenshotData: await screenshotData(), clippedAt: new Date().toISOString()
        };

        const response = await browser.runtime.sendMessage({ type: "elephruit.native.enqueue.v1", clip });
        if (!response?.success) throw new Error(response?.error || "Elephruit didn’t accept the clip.");
        await browser.storage.local.set({ elephruitClipMode: state.mode, elephruitClipTags: byID("tags").value });
        setStatus(response.openedApp ? "Saved to Elephruit." : "Saved. Elephruit will import it when opened.", true);
        byID("save").querySelector("span").textContent = "Saved";
        setTimeout(() => api.closePanel(), 900);
      } catch (error) {
        state.busy = false;
        byID("save").disabled = false;
        byID("save").querySelector("span").textContent = "Try again";
        setStatus(readableError(error));
      }
    }

    async function loadPage() {
      try {
        const page = await withTimeout(Promise.resolve().then(() => api.extract()), 15_000, "Safari took too long to read this page.");
        if (page?.schemaVersion !== 4) throw new Error("Safari couldn’t read this page.");
        if (state.disposed) return;
        state.page = page;
        const sourceURL = new URL(page.sourceURL);
        const siteName = page.siteName || sourceURL.hostname;
        byID("title").value = page.title;
        byID("source").textContent = `${siteName} · ${sourceURL.hostname}`;
        byID("site-letter").textContent = siteName.slice(0, 1).toUpperCase();
        shadow.querySelector("[data-mode='selection']").disabled = !page.selection;
        const saved = await browser.storage.local.get(["elephruitClipMode", "elephruitClipTags"]);
        if (state.disposed) return;
        const preferred = saved.elephruitClipMode;
        await selectMode(preferred === "selection" && !page.selection ? "article" : preferred || "article");
        byID("tags").value = saved.elephruitClipTags || "";
        byID("loading").hidden = true;
        byID("clip-form").hidden = false;
        shadow.querySelector(".panel").scrollTop = 0;
      } catch (error) {
        showFatal(`${readableError(error)} Reload the page once, then try the clipper again.`);
      }
    }

    shadow.querySelectorAll(".mode").forEach((button) => cleaners.push(listen(button, "click", () => {
      selectMode(button.dataset.mode).catch((error) => setStatus(readableError(error)));
    })));
    cleaners.push(listen(byID("article-narrow"), "click", () => adjustArticleBoundary(-1).catch((error) => setStatus(readableError(error)))));
    cleaners.push(listen(byID("article-expand"), "click", () => adjustArticleBoundary(1).catch((error) => setStatus(readableError(error)))));
    cleaners.push(listen(byID("close-panel"), "click", () => api.closePanel()));
    cleaners.push(listen(byID("clip-form"), "submit", save));
    cleaners.push(listen(shadow, "keydown", (event) => {
      if (event.key === "Enter" && event.metaKey) byID("clip-form").requestSubmit();
      if (event.key === "Escape") api.closePanel();
    }));

    activeCleanup = () => {
      if (state.disposed) return;
      state.disposed = true;
      activeApplyBoundary = null;
      cleaners.forEach((clean) => clean());
      api.hideArticleSelection?.();
      shell.remove();
      style.remove();
      activeCleanup = null;
    };
    loadPage();
  }

  globalThis.__elephruitClipperPanelUI = {
    version: 3,
    mount,
    unmount() { activeCleanup?.(); },
    articleChanged(payload) { activeApplyBoundary?.(payload); }
  };
})();
