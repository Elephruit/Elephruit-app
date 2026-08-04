(() => {
  if ((globalThis.__elephruitClipperVersion || 0) >= 2) return;
  globalThis.__elephruitClipperVersion = 2;

  const REMOVE = [
    "script", "style", "noscript", "template", "nav", "form", "button", "input", "select",
    "textarea", "dialog", "iframe", "canvas", "svg", "video", "audio", "object", "embed",
    "[aria-hidden='true']", "[hidden]", ".advertisement", ".advert", ".ads", ".cookie-banner",
    ".newsletter", ".paywall", ".social-share", ".related", ".comments"
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
      const url = absoluteURL(image.currentSrc || image.src || image.getAttribute("src"));
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
    }).sort((left, right) => (right.width * right.height) - (left.width * left.height)).slice(0, 24);
  }

  function linkDensity(element) {
    const textLength = Math.max(element.innerText?.trim().length || 0, 1);
    const linkLength = [...element.querySelectorAll("a")]
      .reduce((total, link) => total + (link.innerText?.trim().length || 0), 0);
    return linkLength / textLength;
  }

  function articleRoot() {
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
      let score = text.length + paragraphs * 90 + headings * 45 - text.length * linkDensity(element) * 1.5;
      if (POSITIVE.test(identity)) score *= 1.25;
      if (NEGATIVE.test(identity)) score *= 0.35;
      if (score > best) {
        winner = element;
        best = score;
      }
    }
    return winner;
  }

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
    const root = articleRoot();
    const article = snapshot(root);
    const simplifiedArticle = snapshot(root, true);
    const fullPage = snapshot(document.body);
    const selected = selectedRoot();
    const selection = selected ? snapshot(selected) : null;
    const canonical = absoluteURL(document.querySelector("link[rel='canonical']")?.href);
    const description = meta("meta[name='description']", "meta[property='og:description']", "meta[name='twitter:description']");

    return {
      schemaVersion: 2,
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
      }))
    };
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
    window.scrollTo(session.x, session.y);
    return afterPaint(true);
  }

  browser.runtime.onMessage.addListener((message) => {
    if (message?.type === "elephruit.extract.v2") return Promise.resolve(extract());
    if (message?.type === "elephruit.capture.start") return Promise.resolve(beginCapture());
    if (message?.type === "elephruit.capture.scroll") return scrollCapture(Number(message.y) || 0);
    if (message?.type === "elephruit.capture.finish") return finishCapture();
    return undefined;
  });
})();
