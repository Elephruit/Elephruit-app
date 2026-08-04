(() => {
  if ((globalThis.__elephruitClipperVersion || 0) >= 16) return;
  globalThis.__elephruitClipperVersion = 16;

  // An already-open tab can retain the previous isolated-world script after an extension update.
  // Remove its detached UI before installing the new API so the next toolbar click cannot produce
  // overlapping panels or boundaries.
  globalThis.__elephruitClipperPanelUI?.unmount?.();
  document.querySelectorAll("[data-elephruit-clipper-ui='panel'], [data-elephruit-clipper-ui='article-boundary']")
    .forEach((element) => element.remove());

  const REMOVE_UNSAFE = [
    "script", "style", "noscript", "template", "form", "button", "input", "select", "textarea",
    "dialog", "iframe", "canvas", "svg", "video", "audio", "object", "embed",
    "[aria-hidden='true']", "[hidden]",
    "[data-elephruit-clipper-ui]"
  ].join(",");
  const REMOVE_SIMPLIFIED = [
    "nav", ".advertisement", ".advert", ".ads", ".cookie-banner", ".newsletter", ".paywall",
    ".social-share", ".related", ".comments"
  ].join(",");
  const REMOVE_WIKIPEDIA_CHROME = [
    ".vector-page-toolbar", ".vector-column-end", ".mw-indicators", ".mw-editsection",
    ".mw-jump-link", ".printfooter", ".catlinks", ".navbox", ".vertical-navbox",
    ".vector-toc-landmark", ".mw-portlet-lang", "[role='navigation']"
  ].join(",");

  const POSITIVE = /article|body|content|entry|main|page|post|story|text/i;
  const NEGATIVE = /ad|banner|breadcrumb|comment|cookie|footer|header|menu|modal|nav|promo|related|share|sidebar|subscribe|widget/i;
  const FIDELITY_STYLE_PROPERTIES = [
    "display", "box-sizing", "float", "clear", "position", "top", "right", "bottom", "left", "z-index",
    "width", "min-width", "max-width",
    "margin-top", "margin-right", "margin-bottom", "margin-left",
    "padding-top", "padding-right", "padding-bottom", "padding-left",
    "border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
    "border-top-style", "border-right-style", "border-bottom-style", "border-left-style",
    "border-top-color", "border-right-color", "border-bottom-color", "border-left-color",
    "border-top-left-radius", "border-top-right-radius", "border-bottom-right-radius", "border-bottom-left-radius",
    "border-collapse", "border-spacing", "background-color", "color", "opacity",
    "font-family", "font-size", "font-weight", "font-style", "font-variant", "line-height",
    "letter-spacing", "word-spacing", "text-align", "text-decoration-line", "text-decoration-color",
    "text-decoration-style", "text-transform", "text-indent", "text-shadow", "white-space",
    "overflow-wrap", "word-break", "list-style-type", "list-style-position",
    "grid-template-columns", "grid-template-rows", "grid-auto-flow", "grid-column", "grid-row",
    "gap", "column-gap", "row-gap", "flex", "flex-basis", "flex-direction", "flex-grow",
    "flex-shrink", "flex-wrap", "align-content", "align-items", "align-self", "justify-content",
    "justify-items", "justify-self", "order", "object-fit", "object-position", "aspect-ratio", "vertical-align"
  ];

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

  function fidelityStyle(element) {
    const computed = getComputedStyle(element);
    return FIDELITY_STYLE_PROPERTIES.flatMap((property) => {
      let value = computed.getPropertyValue(property).trim();
      if (!value) return [];
      if (property === "position" && ["fixed", "sticky"].includes(value)) value = "static";
      if (["top", "right", "bottom", "left", "z-index"].includes(property)
          && ["fixed", "sticky"].includes(computed.position)) return [];
      return [`${property}:${value}`];
    }).join(";");
  }

  function clean(root, simplified = false) {
    const clone = root.cloneNode(true);
    const isWikipedia = /(^|\.)wikipedia\.org$/i.test(location.hostname);
    const wikipediaBody = isWikipedia
      ? root.querySelector("#bodyContent, .mw-body-content")
      : null;
    const capturedWidth = wikipediaBody?.getBoundingClientRect().width
      || root.getBoundingClientRect().width;
    const sourceElements = [root, ...root.querySelectorAll("*")];
    const clonedElements = [clone, ...clone.querySelectorAll("*")];
    const fidelityStyles = new Map();
    if (!simplified) {
      clonedElements.forEach((element, index) => {
        const source = sourceElements[index];
        if (source instanceof Element) fidelityStyles.set(element, fidelityStyle(source));
      });
    }
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
    clone.querySelectorAll(REMOVE_UNSAFE).forEach((node) => node.remove());
    if (simplified) clone.querySelectorAll(REMOVE_SIMPLIFIED).forEach((node) => node.remove());
    if (isWikipedia) {
      clone.querySelectorAll(REMOVE_WIKIPEDIA_CHROME).forEach((node) => node.remove());
      clone.querySelectorAll(".mw-body-header > :not(#firstHeading)").forEach((node) => node.remove());
    }
    [clone, ...clone.querySelectorAll("*")].forEach((element) => {
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
      const generatedStyle = fidelityStyles.get(element);
      if (generatedStyle) element.setAttribute("style", generatedStyle);
    });
    if (isWikipedia) {
      // Vector lays the page shell out with named CSS grid areas. Computed-style capture cannot
      // retain those names, so replaying the shell as a grid can place the actual article well
      // below an empty implicit track. Keep the article's own floats and tables intact while
      // making only Wikipedia's outer shell a straightforward document flow.
      clone.style.cssText = [
        "display:block", "box-sizing:border-box", `width:${capturedWidth}px`,
        "min-width:0", "max-width:none", "margin:0", "padding:0",
        "background-color:transparent", "color:rgb(32, 33, 34)",
        "font-family:sans-serif", "font-size:16px", "line-height:normal"
      ].join(";");
      const header = clone.querySelector(".mw-body-header");
      if (header) {
        header.style.display = "block";
        header.style.width = "100%";
        header.style.margin = "0 0 16px";
      }
      const body = clone.querySelector("#bodyContent, .mw-body-content");
      if (body) {
        body.style.display = "flow-root";
        body.style.width = "100%";
        body.style.margin = "0";
      }
    }
    if (capturedWidth > 0) clone.dataset.elephruitCapturedWidth = String(Math.round(capturedWidth * 100) / 100);
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
    const textLength = Math.max(element.textContent?.trim().length || 0, 1);
    const links = [...element.querySelectorAll("a")].slice(0, 200);
    const linkLength = links.reduce((total, link) => total + (link.textContent?.trim().length || 0), 0);
    return linkLength / textLength;
  }

  function articleRoot() {
    if (/(^|\.)wikipedia\.org$/i.test(location.hostname)) {
      const wikipediaArticle = document.querySelector("main#content, main.mw-body, #content.mw-body");
      if (wikipediaArticle) return wikipediaArticle;
    }

    const viewportArticles = [...document.querySelectorAll("article")]
      .filter((element) => {
        const text = element.textContent?.trim() || "";
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
        const textLength = element.textContent?.trim().length || 0;
        const paragraphs = element.querySelectorAll("p").length;
        const quality = Math.min(textLength, 6_000) + Math.min(paragraphs, 30) * 100 - textLength * linkDensity(element);
        const score = quality + Math.min(visible, window.innerHeight) * 8 - distance * 2;
        return !winner || score > winner.score ? { element, score } : winner;
      }, null).element;
    }

    // Avoid walking and rescoring every div on large pages. Modern article pages nearly always
    // expose a semantic or identity-bearing container; direct body children cover the fallback.
    const semantic = [...document.querySelectorAll([
      "article", "main", "[role='main']", "[itemprop='articleBody']", ".article-body",
      ".article-content", ".entry-content", ".post-content", ".story-body", "#article-body",
      "#content", "#main-content"
    ].join(","))].slice(0, 80);
    const bodyChildren = [...(document.body?.children || [])].slice(0, 40);
    const candidates = [...new Set([...semantic, ...bodyChildren])];
    let winner = document.body;
    let best = 0;

    for (const element of candidates) {
      const text = element.textContent?.trim() || "";
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
    const heading = root.querySelector("h1, h2, h3");
    let candidate = heading?.querySelector("a") || heading || root;
    const levels = [];

    // Every ancestor already contains the chosen heading, so it is a valid cheap boundary. Keep
    // structural wrappers even when their rectangles are similar; no text or style snapshot is
    // generated until Save.
    while (candidate && candidate !== document.documentElement && levels.length < 16) {
      const rect = candidate.getBoundingClientRect();
      if (rect.width >= 40 && rect.height >= 18) {
        levels.push(candidate);
      }
      if (candidate === document.body) break;
      candidate = candidate.parentElement;
    }

    if (!levels.includes(root)) levels.push(root);
    return levels;
  }

  function ensureArticleSelection() {
    if (articleSelection?.levels?.[0]?.isConnected) return articleSelection;
    const root = articleRoot();
    const levels = articleSelectionLevels(root);
    articleSelection = { levels, index: Math.max(0, levels.indexOf(root)) };
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
    const preview = quickSnapshot(root);
    return {
      article: preview,
      simplifiedArticle: preview,
      boundary: {
        level: selection.index + 1,
        levelCount: selection.levels.length,
        canNarrow: selection.index > 0,
        canExpand: selection.index < selection.levels.length - 1,
        characterCount: root.textContent?.trim().length || 0
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

  function quickText(root, maximumLength = 6_000) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const parts = [];
    let length = 0;
    while (length < maximumLength) {
      const node = walker.nextNode();
      if (!node) break;
      const parent = node.parentElement;
      if (!parent || parent.closest(REMOVE_UNSAFE)) continue;
      const value = node.textContent?.replace(/\s+/g, " ").trim();
      if (!value) continue;
      const available = maximumLength - length;
      parts.push(value.slice(0, available));
      length += Math.min(value.length, available);
    }
    return parts.join(" ").replace(/\s+/g, " ").trim();
  }

  function previewImage(root) {
    let inspected = 0;
    for (const image of root.getElementsByTagName?.("img") || []) {
      inspected += 1;
      if (inspected > 200) break;
      const url = absoluteURL(
        image.currentSrc
        || image.getAttribute("data-src")
        || image.getAttribute("data-lazy-src")
        || image.getAttribute("data-original")
        || image.getAttribute("src")
      );
      const width = Number(image.naturalWidth || image.width || 0);
      const height = Number(image.naturalHeight || image.height || 0);
      if (url && width >= 120 && height >= 80) {
        return [{ url, alt: (image.alt || image.getAttribute("aria-label") || "").trim().slice(0, 500), width, height }];
      }
    }
    return [];
  }

  function quickSnapshot(root) {
    return {
      markdown: "",
      html: null,
      text: quickText(root),
      images: previewImage(root)
    };
  }

  function captureContent(mode) {
    if (mode === "article") return snapshot(selectedArticleRoot());
    if (mode === "simplifiedArticle") return snapshot(selectedArticleRoot(), true);
    if (mode === "fullPage") return snapshot(document.body);
    if (mode === "selection") {
      const selected = selectedRoot();
      return selected ? snapshot(selected) : { markdown: "", html: null, text: "", images: [] };
    }
    return null;
  }

  function extract() {
    const root = selectedArticleRoot();
    const article = quickSnapshot(root);
    const fullPage = quickSnapshot(document.body);
    const selected = selectedRoot();
    const selection = selected ? quickSnapshot(selected) : null;
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
      simplifiedArticle: article,
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
    version: 16,
    extract,
    captureContent,
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
    if (message?.type === "elephruit.panel.open.v1") return openPanel();
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
