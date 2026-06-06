(() => {
  const contentEl = document.getElementById("content");
  const tocSidebar = document.getElementById("toc-sidebar");
  const payloadEl = document.getElementById("viewer-data");
  const decoder = new TextDecoder();
  const searchState = {
    query: "",
    matches: [],
    activeIndex: -1,
    panelEl: null,
    inputEl: null,
    countEl: null,
  };
  let renderedContentHtml = "";
  let renderedDocumentTitle = document.title;
  let mermaidRenderGeneration = 0;
  let tocVisible = false;

  // ─── Theme Management ───────────────────────────────────────────────

  function getMode() {
    return localStorage.getItem("qmd-theme") || "auto";
  }

  function getEffectiveTheme() {
    const mode = getMode();
    if (mode === "dark" || mode === "light") return mode;
    return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  function updateHljsTheme() {
    const theme = getEffectiveTheme();
    const lightSheet = document.getElementById("hljs-light");
    const darkSheet = document.getElementById("hljs-dark");
    if (lightSheet && darkSheet) {
      lightSheet.disabled = theme === "dark";
      darkSheet.disabled = theme === "light";
    }
  }

  function updateToggleButton() {
    const btn = document.querySelector(".theme-toggle");
    if (!btn) return;
    const mode = getMode();
    if (mode === "auto") {
      btn.textContent = "\u25D1";
      btn.setAttribute("aria-label", "Theme: auto");
    } else if (mode === "light") {
      btn.textContent = "\u2600";
      btn.setAttribute("aria-label", "Theme: light");
    } else {
      btn.textContent = "\u263E";
      btn.setAttribute("aria-label", "Theme: dark");
    }
  }

  function applyMode(mode) {
    if (mode === "auto") {
      document.documentElement.removeAttribute("data-theme");
      localStorage.removeItem("qmd-theme");
    } else {
      document.documentElement.setAttribute("data-theme", mode);
      localStorage.setItem("qmd-theme", mode);
    }
    updateToggleButton();
    updateHljsTheme();
    renderMermaidFigures(contentEl);
  }

  function toggleTheme() {
    const mode = getMode();
    if (mode === "auto") applyMode("light");
    else if (mode === "light") applyMode("dark");
    else applyMode("auto");
  }
  window.toggleTheme = toggleTheme;

  function initTheme() {
    const saved = localStorage.getItem("qmd-theme");
    if (saved === "dark" || saved === "light") {
      document.documentElement.setAttribute("data-theme", saved);
    }
    updateHljsTheme();
    window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
      if (getMode() !== "auto") return;
      updateToggleButton();
      updateHljsTheme();
      renderMermaidFigures(contentEl);
    });
  }

  function createToggleButton() {
    const btn = document.createElement("button");
    btn.className = "theme-toggle";
    btn.addEventListener("click", toggleTheme);
    document.body.appendChild(btn);
    updateToggleButton();
  }

  function createTOCToggleButton() {
    const btn = document.createElement("button");
    btn.className = "toc-toggle";
    btn.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M8 5h13"/><path d="M13 12h8"/><path d="M13 19h8"/><path d="M3 10a2 2 0 0 0 2 2h3"/><path d="M3 5v12a2 2 0 0 0 2 2h3"/></svg>';
    btn.setAttribute("aria-label", "Toggle Table of Contents");
    btn.addEventListener("click", toggleTOC);
    document.body.appendChild(btn);
  }

  // ─── TOC Sidebar ───────────────────────────────────────────────────

  function buildTOC() {
    if (!tocSidebar) return;
    const headings = contentEl.querySelectorAll("h1, h2, h3, h4");
    if (headings.length === 0) {
      tocSidebar.innerHTML = '<p class="toc-empty">No headings found</p>';
      return;
    }

    const list = document.createElement("ul");
    list.className = "toc-list";

    headings.forEach((heading, index) => {
      const id = heading.id || `heading-${index}`;
      heading.id = id;

      const li = document.createElement("li");
      li.className = `toc-item toc-item--${heading.tagName.toLowerCase()}`;

      const link = document.createElement("a");
      link.href = `#${id}`;
      link.textContent = heading.textContent;
      link.addEventListener("click", (e) => {
        e.preventDefault();
        heading.scrollIntoView({ behavior: "smooth", block: "start" });
      });

      li.appendChild(link);
      list.appendChild(li);
    });

    tocSidebar.innerHTML = '<h2 class="toc-title">Table of Contents</h2>';
    tocSidebar.appendChild(list);
  }

  function toggleTOC() {
    tocVisible = !tocVisible;
    if (tocSidebar) {
      tocSidebar.classList.toggle("toc-sidebar--visible", tocVisible);
    }
    document.body.classList.toggle("has-toc", tocVisible);
  }
  window.toggleTOC = toggleTOC;

  // ─── Search / Find ─────────────────────────────────────────────────

  function updateSearchCountLabel() {
    if (!searchState.countEl) return;
    if (!searchState.query) { searchState.countEl.textContent = ""; return; }
    if (searchState.matches.length === 0) { searchState.countEl.textContent = "No matches"; return; }
    searchState.countEl.textContent = `${searchState.activeIndex + 1} of ${searchState.matches.length}`;
  }

  function applyRenderedContent() {
    contentEl.innerHTML = renderedContentHtml || "<p></p>";
    enableTaskCheckboxes(contentEl);
    finalizeLinks(contentEl);
    finalizeImages(contentEl);
    highlightCode(contentEl);
    renderMermaidDiagrams(contentEl);
    renderMath(contentEl);
    setupCodeBlockCopy(contentEl);
    buildTOC();
    document.title = renderedDocumentTitle;
  }

  function clearSearchSelection() {
    for (const match of searchState.matches) match.classList.remove("find-match--active");
    searchState.matches = [];
    searchState.activeIndex = -1;
    updateSearchCountLabel();
  }

  function resetSearchHighlights() {
    clearSearchSelection();
    applyRenderedContent();
  }

  function escapeRegExp(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }

  function collectSearchMatches(query) {
    const pattern = new RegExp(escapeRegExp(query), "gi");
    const walker = document.createTreeWalker(contentEl, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        if (!node.nodeValue || !node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
        const parent = node.parentElement;
        if (!parent) return NodeFilter.FILTER_REJECT;
        if (parent.closest(".find-panel")) return NodeFilter.FILTER_REJECT;
        if (["SCRIPT", "STYLE", "NOSCRIPT"].includes(parent.tagName)) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      },
    });

    const textNodes = [];
    while (walker.nextNode()) textNodes.push(walker.currentNode);
    const matches = [];

    for (const textNode of textNodes) {
      const text = textNode.nodeValue;
      pattern.lastIndex = 0;
      let match = pattern.exec(text);
      if (!match) continue;

      const fragment = document.createDocumentFragment();
      let lastIndex = 0;
      while (match) {
        const start = match.index;
        const end = start + match[0].length;
        if (start > lastIndex) fragment.appendChild(document.createTextNode(text.slice(lastIndex, start)));
        const mark = document.createElement("mark");
        mark.className = "find-match";
        mark.textContent = text.slice(start, end);
        fragment.appendChild(mark);
        matches.push(mark);
        lastIndex = end;
        match = pattern.exec(text);
      }
      if (lastIndex < text.length) fragment.appendChild(document.createTextNode(text.slice(lastIndex)));
      textNode.parentNode.replaceChild(fragment, textNode);
    }
    return matches;
  }

  function activateSearchMatch(index, shouldScroll = true) {
    if (searchState.matches.length === 0) { searchState.activeIndex = -1; updateSearchCountLabel(); return; }
    for (const match of searchState.matches) match.classList.remove("find-match--active");
    const normalizedIndex = ((index % searchState.matches.length) + searchState.matches.length) % searchState.matches.length;
    const activeMatch = searchState.matches[normalizedIndex];
    activeMatch.classList.add("find-match--active");
    searchState.activeIndex = normalizedIndex;
    updateSearchCountLabel();
    if (shouldScroll) activeMatch.scrollIntoView({ behavior: "auto", block: "center", inline: "nearest" });
  }

  function updateSearch(query, options = {}) {
    const normalizedQuery = (query || "").trim();
    const preserveIndex = options.preserveIndex === true;
    const previousIndex = searchState.activeIndex;
    searchState.query = normalizedQuery;
    resetSearchHighlights();
    if (!normalizedQuery) return;
    searchState.matches = collectSearchMatches(normalizedQuery);
    if (searchState.matches.length === 0) { updateSearchCountLabel(); return; }
    const nextIndex = preserveIndex && previousIndex >= 0 ? previousIndex : 0;
    activateSearchMatch(nextIndex, options.scrollToMatch !== false);
  }

  function jumpToSearchMatch(direction) {
    if (!searchState.query) { openFindBar(); return; }
    if (searchState.matches.length === 0) updateSearch(searchState.query, { scrollToMatch: false });
    if (searchState.matches.length === 0) return;
    const baseIndex = searchState.activeIndex >= 0 ? searchState.activeIndex : 0;
    activateSearchMatch(baseIndex + direction);
  }

  function closeFindBar() {
    if (!searchState.panelEl) return;
    searchState.panelEl.classList.remove("find-panel--visible");
    searchState.query = "";
    if (searchState.inputEl) searchState.inputEl.value = "";
    resetSearchHighlights();
  }

  function openFindBar() {
    if (!searchState.panelEl) return;
    searchState.panelEl.classList.add("find-panel--visible");
    searchState.inputEl.focus();
    searchState.inputEl.select();
    updateSearch(searchState.inputEl.value, { scrollToMatch: false });
  }

  function toggleFindBar() {
    if (!searchState.panelEl) return;
    if (searchState.panelEl.classList.contains("find-panel--visible")) closeFindBar();
    else openFindBar();
  }

  window.qmdToggleFindBar = toggleFindBar;
  window.qmdFindNextMatch = () => jumpToSearchMatch(1);
  window.qmdFindPreviousMatch = () => jumpToSearchMatch(-1);

  function createSearchPanel() {
    const panel = document.createElement("section");
    panel.className = "find-panel";
    panel.setAttribute("role", "search");

    const input = document.createElement("input");
    input.className = "find-panel__input";
    input.type = "search";
    input.placeholder = "Find in document...";
    input.setAttribute("spellcheck", "false");

    const count = document.createElement("p");
    count.className = "find-panel__count";

    const prevBtn = document.createElement("button");
    prevBtn.className = "find-panel__button";
    prevBtn.textContent = "\u2191";
    prevBtn.addEventListener("click", () => jumpToSearchMatch(-1));

    const nextBtn = document.createElement("button");
    nextBtn.className = "find-panel__button";
    nextBtn.textContent = "\u2193";
    nextBtn.addEventListener("click", () => jumpToSearchMatch(1));

    const closeBtn = document.createElement("button");
    closeBtn.className = "find-panel__button find-panel__button--close";
    closeBtn.textContent = "\u2715";
    closeBtn.addEventListener("click", closeFindBar);

    input.addEventListener("input", () => updateSearch(input.value));
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") { e.preventDefault(); jumpToSearchMatch(e.shiftKey ? -1 : 1); }
      else if (e.key === "Escape") { e.preventDefault(); closeFindBar(); }
    });

    panel.append(input, count, prevBtn, nextBtn, closeBtn);
    document.body.appendChild(panel);
    searchState.panelEl = panel;
    searchState.inputEl = input;
    searchState.countEl = count;
  }

  // ─── Rendering Helpers ─────────────────────────────────────────────

  function decodeBase64Utf8(value) {
    const binary = window.atob(value || "");
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return decoder.decode(bytes);
  }

  function applyBaseUrl(baseUrl) {
    if (!baseUrl) return;
    let baseEl = document.querySelector("base");
    if (!baseEl) { baseEl = document.createElement("base"); document.head.prepend(baseEl); }
    baseEl.href = baseUrl;
  }

  function finalizeLinks(root) {
    const anchors = root.querySelectorAll("a[href]");
    for (const anchor of anchors) {
      const href = anchor.getAttribute("href") || "";
      if (/^https?:\/\//i.test(href)) {
        anchor.setAttribute("target", "_blank");
        anchor.setAttribute("rel", "noopener noreferrer");
      }
    }
  }

  function finalizeImages(root) {
    const images = root.querySelectorAll("img");
    for (const image of images) { image.loading = "lazy"; image.decoding = "async"; }
  }

  function enableTaskCheckboxes(root) {
    const checkboxes = root.querySelectorAll('input[type="checkbox"]');
    checkboxes.forEach((cb, index) => {
      cb.disabled = false;
      cb.style.cursor = "pointer";
      cb.addEventListener("change", () => {
        window.webkit.messageHandlers.checkboxToggle.postMessage({
          index: index,
          checked: cb.checked
        });
      });
    });
  }

  function highlightCode(root) {
    if (!window.hljs) return;
    const blocks = root.querySelectorAll("pre code");
    for (const block of blocks) {
      if (isMermaidCodeBlock(block)) continue;
      window.hljs.highlightElement(block);
    }
  }

  // ─── Mermaid ───────────────────────────────────────────────────────

  function isMermaidCodeBlock(code) {
    return /\b(language-mermaid|mermaid)\b/.test(code.className || "");
  }

  function configureMermaid() {
    if (!window.mermaid) return false;
    window.mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      theme: getEffectiveTheme() === "dark" ? "dark" : "default",
    });
    return true;
  }

  function createMermaidFigure(source) {
    const figure = document.createElement("figure");
    figure.className = "mermaid-diagram";
    figure.dataset.mermaidSource = source;
    const status = document.createElement("p");
    status.className = "mermaid-diagram__status";
    status.textContent = "Rendering diagram...";
    figure.appendChild(status);
    return figure;
  }

  function renderMermaidDiagrams(root) {
    const codeBlocks = root.querySelectorAll("pre code");
    const mermaidBlocks = [];
    for (const code of codeBlocks) {
      if (isMermaidCodeBlock(code)) mermaidBlocks.push(code);
    }
    if (mermaidBlocks.length === 0) return;

    for (const code of mermaidBlocks) {
      const pre = code.parentElement;
      if (!pre) continue;
      const source = code.textContent.trim();
      const figure = createMermaidFigure(source);
      pre.replaceWith(figure);
    }

    renderMermaidFigures(root);
  }

  async function renderMermaidFigures(root) {
    if (!configureMermaid()) return;
    mermaidRenderGeneration++;
    const generation = mermaidRenderGeneration;
    const figures = root.querySelectorAll(".mermaid-diagram");

    for (let i = 0; i < figures.length; i++) {
      const figure = figures[i];
      const source = figure.dataset.mermaidSource;
      if (!source) continue;

      try {
        const id = `qmd-mermaid-${generation}-${i}`;
        const result = await window.mermaid.render(id, source);
        if (generation !== mermaidRenderGeneration) return;
        if (!result.svg) throw new Error("Empty SVG");

        const img = document.createElement("img");
        img.className = "mermaid-diagram__image";
        img.alt = "Mermaid diagram";
        img.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(result.svg)}`;
        figure.classList.remove("mermaid-diagram--error");
        figure.replaceChildren(img);
      } catch (err) {
        if (generation !== mermaidRenderGeneration) return;
        figure.classList.add("mermaid-diagram--error");
        const status = document.createElement("p");
        status.className = "mermaid-diagram__status";
        status.textContent = "Could not render diagram: " + (err.message || "Unknown error");
        const pre = document.createElement("pre");
        const code = document.createElement("code");
        code.textContent = source;
        pre.appendChild(code);
        figure.replaceChildren(status, pre);
      }
    }
  }

  // ─── KaTeX Math ────────────────────────────────────────────────────

  function renderMath(root) {
    if (!window.katex || !window.renderMathInElement) return;
    try {
      window.renderMathInElement(root, {
        delimiters: [
          { left: "$$", right: "$$", display: true },
          { left: "$", right: "$", display: false },
          { left: "\\[", right: "\\]", display: true },
          { left: "\\(", right: "\\)", display: false },
        ],
        throwOnError: false,
      });
    } catch (e) {
      console.error("KaTeX error:", e);
    }
  }

  // ─── Code Copy Button ──────────────────────────────────────────────

  function setupCodeBlockCopy(root) {
    const pres = root.querySelectorAll("pre");
    for (const pre of pres) {
      if (pre.querySelector(".mermaid-diagram__image")) continue;
      const code = pre.querySelector("code");
      if (!code) continue;

      pre.classList.add("code-block--copyable");
      const btn = document.createElement("button");
      btn.className = "code-copy-button";
      btn.innerHTML = '<span class="code-copy-button__label">Copy</span>';
      btn.addEventListener("click", async () => {
        try {
          await navigator.clipboard.writeText(code.textContent);
          btn.innerHTML = '<span class="code-copy-button__label">Copied!</span>';
          btn.dataset.copyState = "copied";
          setTimeout(() => {
            btn.innerHTML = '<span class="code-copy-button__label">Copy</span>';
            delete btn.dataset.copyState;
          }, 2000);
        } catch {
          btn.innerHTML = '<span class="code-copy-button__label">Failed</span>';
          btn.dataset.copyState = "failed";
          setTimeout(() => {
            btn.innerHTML = '<span class="code-copy-button__label">Copy</span>';
            delete btn.dataset.copyState;
          }, 2000);
        }
      });
      pre.appendChild(btn);
    }
  }

  // ─── Marked Configuration ──────────────────────────────────────────

  function configureMarked() {
    if (!window.marked) return;

    window.marked.setOptions({
      gfm: true,
      breaks: false,
      pedantic: false,
      headerIds: true,
      mangle: false,
    });
  }

  // ─── Main Init ─────────────────────────────────────────────────────

  function init() {
    initTheme();
    createToggleButton();
    createTOCToggleButton();
    createSearchPanel();
    configureMarked();

    if (!payloadEl) {
      contentEl.innerHTML = '<p class="document__error">No document data found.</p>';
      return;
    }

    let data;
    try {
      data = JSON.parse(payloadEl.textContent);
    } catch (e) {
      contentEl.innerHTML = '<p class="document__error">Failed to parse document data.</p>';
      return;
    }

    const filename = decodeBase64Utf8(data.filename);
    const baseUrl = decodeBase64Utf8(data.baseUrl);
    const markdown = decodeBase64Utf8(data.markdown);

    applyBaseUrl(baseUrl);
    renderedDocumentTitle = `QuickMD — ${filename}`;

    try {
      const rawHtml = window.marked.parse(markdown);
      renderedContentHtml = window.DOMPurify
        ? window.DOMPurify.sanitize(rawHtml, {
            ADD_TAGS: ["input"],
            ADD_ATTR: ["type", "checked", "disabled", "class"],
            ALLOW_DATA_ATTR: true,
          })
        : rawHtml;
    } catch (e) {
      contentEl.innerHTML = `<p class="document__error">Markdown parsing error: ${e.message}</p>`;
      return;
    }

    applyRenderedContent();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
