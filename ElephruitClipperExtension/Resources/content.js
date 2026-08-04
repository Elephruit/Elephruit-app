(() => {
  if ((globalThis.__elephruitClipperVersion || 0) >= 7) return;
  globalThis.__elephruitClipperVersion = 7;

  const REMOVE = [
    "script", "style", "noscript", "template", "nav", "form", "button", "input", "select",
    "textarea", "dialog", "iframe", "canvas", "svg", "video", "audio", "object", "embed",
    "[aria-hidden='true']", "[hidden]", ".advertisement", ".advert", ".ads", ".cookie-banner",
    ".newsletter", ".paywall", ".social-share", ".related", ".comments",
    "[data-elephruit-clipper-ui]"
  ].join(",");

  const POSITIVE = /article|body|content|entry|main|page|post|story|text/i;
  const NEGATIVE = /ad|banner|breadcrumb|comment|cookie|footer|header|menu|modal|nav|promo|related|share|sidebar|subscribe|widget/i;

  function meta(...selectors) {
    for (const selector of selectors) {
      const value = document.querySelector(selector)?.content?.trim();
      if (value) return value;
    }
    return "";
  }

  function absoluteURL(value) {
    if (!value) return "";
    try {
      const url = new URL(value, document.baseURI);
      return ["http:", "https:"].includes(url.protocol) ? url.href : "";
    } catch {
      return "";
    }
  }

  function clean(root, simplified = false) {
    const clone = root.cloneNode(true);
    const sourceImages = [root, ...root.querySelectorAll("img")].filter((node) => node.tagName?.toLowerCase() === "img");
    const clonedImages = [clone, ...clone.querySelectorAll("img")].filter((node) => node.tagName?.toLowerCase() === "img");
    clonedImages.forEach((image, index) => {
      const source = sourceImages[index];
      const resolved = absoluteURL(
        source?.currentSrc
        || source?.getAttribute("data-src")
        || source?.getAttribute("data-lazy-src")
        || source?.getAttribute("data-original")
        || source?.getAttribute("src")
      );
      if (resolved) image.setAttribute("src", resolved);
    });
    clone.querySelectorAll(REMOVE).forEach((node) => node.remove());
    clone.querySelectorAll("*").forEach((element) => {
      for (const attribute of [...element.attributes]) {
        const name = attribute.name.toLowerCase();
        if (name.startsWith("on") || ["style", "srcset", "formaction", "ping", "nonce"].includes(name)) {
          element.removeAttribute(attribute.name);
        }
        if (simplified && ["class", "id", "role"].includes(name)) element.removeAttribute(attribute.name);
      }
      if (element.hasAttribute("href")) {
        const href = absoluteURL(element.getAttribute("href"));
        href ? element.setAttribute("href", href) : element.removeAttribute("href");
      }
      if (element.hasAttribute("src")) {
        const source = absoluteURL(element.getAttribute("src"));
        source ? element.setAttribute("src", source) : element.removeAttribute("src");
      }
    });
    return clone;
  }

  function imageCandidates(root) {
    const seen = new Set();
    return [...root.querySelectorAll("img")].flatMap((image) => {
      const url = absoluteURL(
        image.currentSrc
        || image.getAttribute("data-src")
        || image.getAttribute("data-lazy-src")
        || image.getAttribute("data-original")
        || image.src
        || image.getAttribute("src")
      );
      if (!url || seen.has(url)) return [];
      const width = Number(image.naturalWidth || image.width || 0);
      const height = Number(image.naturalHeight || image.height || 0);
      if (width < 120 || height < 80) return [];
      seen.add(url);
      return [{
        url,
        alt: (image.alt || image.getAttribute("aria-label") || "").trim().slice(0, 500),
        width,
        height
      }];
    }).slice(0, 24);
  }

  function linkDensity(element) {
    const textLength = Math.max(element.innerText?.trim().length || 0, 1);
    const linkLength = [...element.querySelectorAll("a")]
      .reduce((total, link) => total + (link.innerText?.trim().length || 0), 0);
    return linkLength / textLength;
  }

  function articleRoot() {
    const viewportArticles = [...document.querySelectorAll("article")]
      .filter((element) => {
        const text = element.innerText?.trim() || "";
        const identity = `${element.id} ${element.className}`;
        return text.length >= 300
          && (element.querySelectorAll("p").length >= 2 || text.length >= 800)
          && !NEGATIVE.test(identity);
      });

    if (viewportArticles.length) {
      const center = window.innerHeight / 2;
      return viewportArticles.reduce((winner, element) => {
        const rect = element.getBoundingClientRect();
        const visible = Math.max(0, Math.min(rect.bottom, window.innerHeight) - Math.max(rect.top, 0));
        const distance = visible > 0
          ? Math.abs(Math.max(0, Math.min(window.innerHeight, rect.top + rect.height / 2)) - center)
          : Math.min(Math.abs(rect.top - center), Math.abs(rect.bottom - center));
        const textLength = element.innerText?.trim().length || 0;
        const paragraphs = element.querySelectorAll("p").length;
        const quality = Math.min(textLength, 6_000) + Math.min(paragraphs, 30) * 100 - textLength * linkDensity(element);
        const score = quality + Math.min(visible, window.innerHeight) * 8 - distance * 2;
        return !winner || score > winner.score ? { element, score } : winner;
      }, null).element;
    }

    const semantic = [...document.querySelectorAll("article, main, [role='main']")];
    const broad = [...document.querySelectorAll("section, div")]
      .filter((element) => element.querySelectorAll(":scope > p, :scope > section > p").length >= 2);
    const candidates = [...new Set([...semantic, ...broad])];
    let winner = document.body;
    let best = 0;

    for (const element of candidates) {
      const text = element.innerText?.trim() || "";
      if (text.length < 180) continue;
      const paragraphs = element.querySelectorAll("p").length;
      const headings = element.querySelectorAll("h1, h2, h3").length;
      const identity = `${element.id} ${element.className}`;
      let score = Math.min(text.length, 12_000) + paragraphs * 90 + headings * 45 - text.length * linkDensity(element) * 1.5;
      if (POSITIVE.test(identity)) score *= 1.25;
      if (NEGATIVE.test(identity)) score *= 0.35;
      if (score > best) {
        winner = element;
        best = score;
      }
    }
    return winner;
  }

  let articleSelection = null;
  let articleOverlay = null;
  let clipperPanel = null;

  function articleSelectionLevels(root) {
    const levels = [root];
    const originalTextLength = Math.max(root.innerText?.trim().length || 0, 1);
    let previous = root;
    let candidate = root.parentElement;

    while (candidate && candidate !== document.body && candidate !== document.documentElement && levels.length < 7) {
      const textLength = candidate.innerText?.trim().length || 0;
      const identity = `${candidate.tagName} ${candidate.id} ${candidate.className}`;
      const rect = candidate.getBoundingClientRect();
      const previousRect = previous.getBoundingClientRect();
      const visualGrowth = Math.abs(rect.width - previousRect.width) >= 36
        || Math.abs(rect.height - previousRect.height) >= 48;
      const textGrowth = textLength >= (previous.innerText?.trim().length || 0) * 1.05;
      const isMeaningful = rect.width >= 180
        && rect.height >= 120
        && textLength >= originalTextLength
        && textLength <= originalTextLength * 3.5
        && linkDensity(candidate) < 0.72
        && !NEGATIVE.test(identity)
        && (visualGrowth || textGrowth || /article|main|content|entry|page|post|story/i.test(identity));
      if (isMeaningful) {
        levels.push(candidate);
        previous = candidate;
      }
      candidate = candidate.parentElement;
    }
    return levels;
  }

  function ensureArticleSelection() {
    if (articleSelection?.levels?.[0]?.isConnected) return articleSelection;
    const root = articleRoot();
    articleSelection = { levels: articleSelectionLevels(root), index: 0 };
    return articleSelection;
  }

  function selectedArticleRoot() {
    const selection = ensureArticleSelection();
    return selection.levels[selection.index] || selection.levels[0];
  }

  function makeOverlay() {
    if (articleOverlay?.host?.isConnected) return articleOverlay;
    const host = document.createElement("div");
    host.dataset.elephruitClipperUi = "article-boundary";
    host.style.cssText = "position:fixed;inset:0;z-index:2147483646;pointer-events:none;";
    const shadow = host.attachShadow({ mode: "closed" });
    const style = document.createElement("style");
    style.textContent = `
      :host { all: initial; }
      .shade { position: fixed; background: rgba(24, 31, 26, .58); pointer-events: none; }
      .outline { position: fixed; border: 3px solid #24a148; box-sizing: border-box;
        box-shadow: 0 0 0 1px rgba(255,255,255,.82), 0 3px 18px rgba(0,0,0,.26);
        pointer-events: none; }
      .controls { position: fixed; display: flex; overflow: hidden; border: 1px solid rgba(255,255,255,.2);
        border-radius: 7px; background: #25302a; box-shadow: 0 3px 12px rgba(0,0,0,.3);
        pointer-events: auto; transform: translate(-50%, -50%); }
      button { width: 38px; height: 30px; padding: 0; border: 0; background: transparent; color: white;
        font: 700 20px/30px -apple-system, BlinkMacSystemFont, sans-serif; cursor: pointer; }
      button + button { border-left: 1px solid rgba(255,255,255,.18); }
      button:hover:not(:disabled) { background: #347244; }
      button:disabled { color: rgba(255,255,255,.28); cursor: default; }
    `;
    const shades = Array.from({ length: 4 }, () => {
      const shade = document.createElement("div");
      shade.className = "shade";
      shadow.append(shade);
      return shade;
    });
    const outline = document.createElement("div");
    outline.className = "outline";
    const controls = document.createElement("div");
    controls.className = "controls";
    const narrower = document.createElement("button");
    narrower.type = "button";
    narrower.textContent = "−";
    narrower.title = "Narrow article boundary";
    narrower.setAttribute("aria-label", narrower.title);
    const broader = document.createElement("button");
    broader.type = "button";
    broader.textContent = "+";
    broader.title = "Expand article boundary";
    broader.setAttribute("aria-label", broader.title);
    narrower.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      adjustArticleSelection(-1, true);
    });
    broader.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      adjustArticleSelection(1, true);
    });
    controls.append(narrower, broader);
    shadow.append(style, outline, controls);
    document.documentElement.append(host);
    articleOverlay = { host, shades, outline, controls, narrower, broader };
    return articleOverlay;
  }

  function renderArticleOverlay() {
    if (!articleOverlay?.host?.isConnected) return;
    const selection = ensureArticleSelection();
    const rect = selectedArticleRoot().getBoundingClientRect();
    const left = Math.max(0, Math.min(window.innerWidth, rect.left));
    const right = Math.max(left, Math.min(window.innerWidth, rect.right));
    const top = Math.max(0, Math.min(window.innerHeight, rect.top));
    const bottom = Math.max(top, Math.min(window.innerHeight, rect.bottom));
    const width = Math.max(0, right - left);
    const height = Math.max(0, bottom - top);
    const [above, below, before, after] = articleOverlay.shades;
    above.style.cssText = `left:0;top:0;width:100vw;height:${top}px`;
    below.style.cssText = `left:0;top:${bottom}px;width:100vw;height:${Math.max(0, window.innerHeight - bottom)}px`;
    before.style.cssText = `left:0;top:${top}px;width:${left}px;height:${height}px`;
    after.style.cssText = `left:${right}px;top:${top}px;width:${Math.max(0, window.innerWidth - right)}px;height:${height}px`;
    articleOverlay.outline.style.cssText = `left:${left}px;top:${top}px;width:${width}px;height:${height}px`;
    articleOverlay.controls.style.left = `${left + width / 2}px`;
    articleOverlay.controls.style.top = `${Math.max(17, Math.min(window.innerHeight - 17, top))}px`;
    articleOverlay.narrower.disabled = selection.index === 0;
    articleOverlay.broader.disabled = selection.index >= selection.levels.length - 1;
  }

  function articleSelectionPayload() {
    const selection = ensureArticleSelection();
    const root = selectedArticleRoot();
    return {
      article: snapshot(root),
      simplifiedArticle: snapshot(root, true),
      boundary: {
        level: selection.index + 1,
        levelCount: selection.levels.length,
        canNarrow: selection.index > 0,
        canExpand: selection.index < selection.levels.length - 1,
        characterCount: root.innerText?.trim().length || 0
      }
    };
  }

  function showArticleSelection() {
    const root = selectedArticleRoot();
    const overlay = makeOverlay();
    overlay.host.hidden = false;
    if (root.getBoundingClientRect().bottom < 80 || root.getBoundingClientRect().top > window.innerHeight - 80) {
      root.scrollIntoView({ block: "center", behavior: "smooth" });
    }
    renderArticleOverlay();
    return articleSelectionPayload();
  }

  function hideArticleSelection() {
    if (articleOverlay?.host) articleOverlay.host.remove();
    articleOverlay = null;
    return true;
  }

  function adjustArticleSelection(delta, announce = false) {
    const selection = ensureArticleSelection();
    selection.index = Math.max(0, Math.min(selection.levels.length - 1, selection.index + delta));
    renderArticleOverlay();
    const payload = articleSelectionPayload();
    if (announce) {
      globalThis.__elephruitClipperPanelUI?.articleChanged(payload);
    }
    return payload;
  }

  function openPanel() {
    if (clipperPanel?.host?.isConnected) return { open: true };
    const host = document.createElement("div");
    host.dataset.elephruitClipperUi = "panel";
    host.style.cssText = "position:fixed;inset:0;z-index:2147483647;pointer-events:none;";
    const shadow = host.attachShadow({ mode: "closed" });
    document.documentElement.append(host);
    clipperPanel = { host, shadow };
    const panelUI = globalThis.__elephruitClipperPanelUI;
    if (!panelUI || panelUI.version < 1) {
      host.remove();
      clipperPanel = null;
      throw new Error("The clipper panel is not ready.");
    }
    panelUI.mount(shadow, globalThis.__elephruitClipperAPI);
    return { open: true };
  }

  function closePanel() {
    hideArticleSelection();
    const panel = clipperPanel;
    clipperPanel = null;
    globalThis.__elephruitClipperPanelUI?.unmount();
    panel?.host?.remove();
    return { open: false };
  }

  function togglePanel() {
    return clipperPanel?.host?.isConnected ? closePanel() : openPanel();
  }

  window.addEventListener("scroll", renderArticleOverlay, { passive: true });
  window.addEventListener("resize", renderArticleOverlay, { passive: true });

  function selectedRoot() {
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed || !selection.toString().trim()) return null;
    const wrapper = document.createElement("section");
    for (let index = 0; index < selection.rangeCount; index += 1) {
      wrapper.append(selection.getRangeAt(index).cloneContents());
    }
    return wrapper;
  }

  function escapeMarkdown(text) {
    return text.replace(/([\\`*_[\]<>])/g, "\\$1");
  }

  function markdownFor(node, depth = 0) {
    if (node.nodeType === Node.TEXT_NODE) return escapeMarkdown(node.textContent.replace(/\s+/g, " "));
    if (node.nodeType !== Node.ELEMENT_NODE) return "";
    const tag = node.tagName.toLowerCase();
    const children = () => [...node.childNodes].map((child) => markdownFor(child, depth)).join("");
    const content = children().trim();

    if (/^h[1-6]$/.test(tag)) return `\n\n${"#".repeat(Number(tag[1]))} ${content}\n\n`;
    if (tag === "p") return content ? `\n\n${content}\n\n` : "";
    if (tag === "br") return "  \n";
    if (["strong", "b"].includes(tag)) return content ? `**${content}**` : "";
    if (["em", "i"].includes(tag)) return content ? `_${content}_` : "";
    if (tag === "code" && node.parentElement?.tagName.toLowerCase() !== "pre") return `\`${content}\``;
    if (tag === "pre") return `\n\n\`\`\`\n${node.textContent.trim()}\n\`\`\`\n\n`;
    if (tag === "a") {
      const href = node.getAttribute("href");
      return href && content ? `[${content}](${href})` : content;
    }
    if (tag === "img") {
      const src = node.getAttribute("src");
      return src ? `![${escapeMarkdown(node.getAttribute("alt") || "Image")}](${src})` : "";
    }
    if (tag === "li") {
      const ordered = node.parentElement?.tagName.toLowerCase() === "ol";
      const index = ordered ? [...node.parentElement.children].indexOf(node) + 1 : 0;
      return `\n${"  ".repeat(depth)}${ordered ? `${index}.` : "-"} ${[...node.childNodes].map((child) => markdownFor(child, depth + 1)).join("").trim()}`;
    }
    if (["ul", "ol"].includes(tag)) return `\n${[...node.childNodes].map((child) => markdownFor(child, depth)).join("")}\n`;
    if (tag === "blockquote") return `\n\n${content.split("\n").map((line) => `> ${line}`).join("\n")}\n\n`;
    if (tag === "hr") return "\n\n---\n\n";
    if (tag === "tr") return `\n| ${[...node.children].map((cell) => markdownFor(cell, depth).trim()).join(" | ")} |`;
    if (["td", "th"].includes(tag)) return content;
    return children();
  }

  function normalizedMarkdown(root) {
    return markdownFor(root)
      .replace(/[ \t]+\n/g, "\n")
      .replace(/\n{3,}/g, "\n\n")
      .trim();
  }

  function snapshot(root, simplified = false) {
    const images = imageCandidates(root);
    const cleaned = clean(root, simplified);
    return {
      markdown: normalizedMarkdown(cleaned),
      html: cleaned.outerHTML,
      text: cleaned.textContent.replace(/\s+/g, " ").trim(),
      images
    };
  }

  function extract() {
    const root = selectedArticleRoot();
    const article = snapshot(root);
    const simplifiedArticle = snapshot(root, true);
    const fullPage = snapshot(document.body);
    const selected = selectedRoot();
    const selection = selected ? snapshot(selected) : null;
    const canonical = absoluteURL(document.querySelector("link[rel='canonical']")?.href);
    const description = meta("meta[name='description']", "meta[property='og:description']", "meta[name='twitter:description']");

    return {
      schemaVersion: 4,
      title: meta("meta[property='og:title']", "meta[name='twitter:title']") || document.title || location.hostname,
      sourceURL: location.href,
      canonicalURL: canonical,
      siteName: meta("meta[property='og:site_name']", "meta[name='application-name']") || location.hostname,
      author: meta("meta[name='author']", "meta[property='article:author']"),
      excerpt: description || article.text.slice(0, 320),
      article,
      simplifiedArticle,
      fullPage,
      selection
    };
  }

  let captureSession = null;

  function pageSize() {
    const body = document.body;
    const root = document.documentElement;
    return {
      viewportWidth: window.innerWidth,
      viewportHeight: window.innerHeight,
      pageWidth: Math.max(root.scrollWidth, body?.scrollWidth || 0, window.innerWidth),
      pageHeight: Math.max(root.scrollHeight, body?.scrollHeight || 0, window.innerHeight),
      devicePixelRatio: window.devicePixelRatio || 1
    };
  }

  function beginCapture() {
    if (captureSession) return pageSize();
    const fixed = [...document.querySelectorAll("body *")].filter((element) => {
      const position = getComputedStyle(element).position;
      return position === "fixed" || position === "sticky";
    });
    captureSession = {
      x: window.scrollX,
      y: window.scrollY,
      scrollBehavior: document.documentElement.style.scrollBehavior,
      fixed: fixed.map((element) => ({
        element,
        visibility: element.style.getPropertyValue("visibility"),
        priority: element.style.getPropertyPriority("visibility")
      })),
      panelVisibility: clipperPanel?.host?.style.visibility || ""
    };
    if (clipperPanel?.host) clipperPanel.host.style.visibility = "hidden";
    document.documentElement.style.setProperty("scroll-behavior", "auto", "important");
    return pageSize();
  }

  function afterPaint(value) {
    return new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve(value))));
  }

  function scrollCapture(y) {
    if (!captureSession) beginCapture();
    captureSession.fixed.forEach(({ element, visibility, priority }) => {
      if (y > 0) element.style.setProperty("visibility", "hidden", "important");
      else if (visibility) element.style.setProperty("visibility", visibility, priority);
      else element.style.removeProperty("visibility");
    });
    window.scrollTo(0, y);
    return afterPaint({ scrollY: window.scrollY, ...pageSize() });
  }

  function finishCapture() {
    if (!captureSession) return Promise.resolve(true);
    const session = captureSession;
    captureSession = null;
    document.documentElement.style.scrollBehavior = session.scrollBehavior;
    session.fixed.forEach(({ element, visibility, priority }) => {
      if (visibility) element.style.setProperty("visibility", visibility, priority);
      else element.style.removeProperty("visibility");
    });
    if (clipperPanel?.host) clipperPanel.host.style.visibility = session.panelVisibility;
    window.scrollTo(session.x, session.y);
    return afterPaint(true);
  }

  // A stable callable surface for the popup. Direct invocation matters during extension upgrades:
  // an already-open tab can still have the previous message listener, and Safari is allowed to use
  // that listener's empty response before the new listener answers. `scripting.executeScript` calls
  // this newest API explicitly, so upgrading never requires the user to reload their page.
  globalThis.__elephruitClipperAPI = {
    version: 7,
    extract,
    showArticleSelection,
    hideArticleSelection,
    adjustArticleSelection,
    openPanel,
    closePanel,
    togglePanel,
    beginCapture,
    scrollCapture,
    finishCapture
  };

  browser.runtime.onMessage.addListener((message) => {
    if (message?.type === "elephruit.panel.toggle.v2") return Promise.resolve(togglePanel());
    if (message?.type === "elephruit.extract.v4") return Promise.resolve(extract());
    if (message?.type === "elephruit.article.show.v4") return Promise.resolve(showArticleSelection());
    if (message?.type === "elephruit.article.adjust.v4") {
      return Promise.resolve(adjustArticleSelection(Number(message.delta) || 0));
    }
    if (message?.type === "elephruit.article.hide.v4") return Promise.resolve(hideArticleSelection());
    if (message?.type === "elephruit.capture.start.v3") return Promise.resolve(beginCapture());
    if (message?.type === "elephruit.capture.scroll.v3") return scrollCapture(Number(message.y) || 0);
    if (message?.type === "elephruit.capture.finish.v3") return finishCapture();
    return undefined;
  });
})();
