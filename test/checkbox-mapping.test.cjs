// Proves the viewer's checkbox source-mapping (computeTaskCheckboxOffsets in src/viewer.js)
// stays in lockstep with the checkboxes marked.js renders:
//   * exactly one entry per rendered checkbox (index alignment),
//   * every EDITABLE entry points at a literal "[ ]"/"[x]" in the ORIGINAL source,
//   * nested-list and blockquote checkboxes are non-editable (offset === null),
//   * offsets stay correct for CRLF / lone-CR files (marked normalizes raw to "\n"),
//   * offsets stay correct when marked drops constructs from the token list
//     (e.g. link reference definitions go to tokens.links, emit no token).
// This mirror MUST match the walk in src/viewer.js. If you change one, change both.
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const marked = require(path.join(root, "QuickMDPreview", "vendor", "marked.min.js"));
const md = fs.readFileSync(path.join(root, "test", "fixtures", "checkbox-mix.md"), "utf8");

function computeTaskCheckboxOffsets(markdown) {
  const out = [];
  let lf = "";
  const lfToOrig = [];
  for (let i = 0; i < markdown.length; i++) {
    const ch = markdown[i];
    if (ch === "\r") {
      if (markdown[i + 1] === "\n") continue;
      lfToOrig.push(i); lf += "\n"; continue;
    }
    lfToOrig.push(i); lf += ch;
  }
  lfToOrig.push(markdown.length);

  const tokens = marked.lexer(lf);

  const n = lf.length;
  const isWs = (c) => c === " " || c === "\t";
  const skipWs = (p) => { while (p < n && isWs(lf[p])) p++; return p; };
  const normLabel = (l) => l.trim().replace(/\s+/g, " ").toLowerCase();
  const labels = new Set(Object.keys(tokens.links || {}).map(normLabel));

  const defEnd = (pos) => {
    let j = pos, sp = 0;
    while (j < n && lf[j] === " " && sp < 3) { j++; sp++; }
    if (lf[j] !== "[") return -1;
    const close = lf.indexOf("]:", j + 1);
    const nl = lf.indexOf("\n", j + 1);
    if (close < 0 || (nl >= 0 && close > nl)) return -1;
    if (!labels.has(normLabel(lf.slice(j + 1, close)))) return -1;
    let k = skipWs(close + 2);
    if (lf[k] === "\n") k = skipWs(k + 1);
    if (lf[k] === "<") { const e = lf.indexOf(">", k + 1); k = e < 0 ? n : e + 1; }
    else { while (k < n && !/\s/.test(lf[k])) k++; }
    let end = k;
    let m = skipWs(k), nlBefore = false;
    if (lf[m] === "\n") { nlBefore = true; m = skipWs(m + 1); }
    const t = lf[m];
    if (t === '"' || t === "'" || t === "(") {
      const closer = t === "(" ? ")" : t;
      for (let p = m + 1; p < n; p++) {
        if (lf[p] === "\\") { p++; continue; }
        if (lf[p] === closer) { end = p + 1; break; }
      }
    } else if (nlBefore) { /* def ends at destination */ }
    return end;
  };

  const skipDroppedDefs = (pos) => {
    for (;;) {
      const end = defEnd(pos);
      if (end < 0) break;
      let p = end;
      while (p < n && lf[p] !== "\n") p++;
      if (p < n) p++;
      for (;;) {
        let q = p;
        while (q < n && lf[q] !== "\n" && isWs(lf[q])) q++;
        if (q < n && lf[q] === "\n") { p = q + 1; continue; }
        if (q >= n) p = n;
        break;
      }
      pos = p;
    }
    return pos;
  };

  const countTasks = (toks) => {
    let c = 0;
    for (const token of toks) {
      if (token.type === "list") {
        for (const item of token.items) {
          if (item.task) c++;
          if (item.tokens) c += countTasks(item.tokens);
        }
      } else if (token.tokens) {
        c += countTasks(token.tokens);
      }
    }
    return c;
  };

  const countListTasks = (toks) => {
    let c = 0;
    for (const token of toks) {
      if (token.type === "list") {
        for (const item of token.items) {
          if (item.task) c++;
          if (item.tokens) c += countListTasks(item.tokens);
        }
      }
    }
    return c;
  };

  const taskMarker = /^[ \t]*(?:[-*+]|\d+[.)])[ \t]+(\[[ xX]\])/;
  const scanTaskMarkers = (from, to) => {
    const found = [];
    let i = from;
    let fence = null;
    while (i < to) {
      let lineEnd = lf.indexOf("\n", i);
      if (lineEnd < 0 || lineEnd > to) lineEnd = to;
      let s = i, sp = 0;
      while (s < lineEnd && lf[s] === " " && sp < 3) { s++; sp++; }
      const fch = lf[s];
      let runLen = 0;
      if (fch === "`" || fch === "~") { let p = s; while (p < lineEnd && lf[p] === fch) { runLen++; p++; } }
      const isFence = runLen >= 3;
      if (fence) {
        if (isFence && fch === fence.char && runLen >= fence.len) fence = null;
        i = lineEnd + 1; continue;
      }
      if (isFence) { fence = { char: fch, len: runLen }; i = lineEnd + 1; continue; }
      const line = lf.slice(i, lineEnd);
      const m = taskMarker.exec(line);
      if (m) found.push(i + m.index + m[0].length - m[1].length);
      i = lineEnd + 1;
    }
    return found;
  };

  let cursor = 0;
  for (const token of tokens) {
    cursor = skipDroppedDefs(cursor);
    let base;
    if (lf.startsWith(token.raw, cursor)) {
      base = cursor;
    } else {
      base = cursor;
      for (let from = cursor; ; ) {
        const idx = lf.indexOf(token.raw, from);
        if (idx < 0) break;
        if (idx === 0 || lf[idx - 1] === "\n") { base = idx; break; }
        from = idx + 1;
      }
    }
    if (token.type === "list") {
      const total = countTasks([token]);
      const listTasks = countListTasks([token]);
      const markers = scanTaskMarkers(base, base + token.raw.length);
      if (total === listTasks && markers.length === listTasks) {
        for (const off of markers) out.push({ offset: lfToOrig[off] });
      } else {
        for (let z = 0; z < total; z++) out.push({ offset: null });
      }
    } else if (token.type === "blockquote") {
      const expected = countTasks([token]);
      for (let z = 0; z < expected; z++) out.push({ offset: null });
    }
    cursor = base + token.raw.length;
  }
  return out;
}

let ok = true;
const fail = (msg) => { console.error("FAIL: " + msg); ok = false; };

function check(label, source, opts = {}) {
  const entries = computeTaskCheckboxOffsets(source);
  const html = marked.parse(source);
  const rendered = (html.match(/<input[^>]*type="checkbox"/g) || []).length;
  const editable = entries.filter((e) => e.offset != null);
  const readonly = entries.length - editable.length;
  console.log(`[${label}] rendered: ${rendered}, entries: ${entries.length}, editable: ${editable.length}, display-only: ${readonly}`);

  if (rendered !== entries.length) fail(`[${label}] entry count ${entries.length} != rendered ${rendered}`);
  for (const e of editable) {
    const marker = source.substr(e.offset, 3);
    if (!/^\[[ xX]\]$/.test(marker)) fail(`[${label}] editable offset ${e.offset} points at ${JSON.stringify(marker)}, not a checkbox`);
  }
  if (opts.minReadonly != null && readonly < opts.minReadonly) fail(`[${label}] expected >=${opts.minReadonly} display-only, got ${readonly}`);
  if (opts.minRendered != null && rendered < opts.minRendered) fail(`[${label}] expected >=${opts.minRendered} checkboxes, got ${rendered}`);
  if (opts.minEditable != null && editable.length < opts.minEditable) fail(`[${label}] expected >=${opts.minEditable} editable, got ${editable.length}`);
  if (opts.maxEditable != null && editable.length > opts.maxEditable) fail(`[${label}] expected <=${opts.maxEditable} editable, got ${editable.length}`);
  // For collision fixtures the decoy marker sits earlier (inside a link def); the real,
  // rendered task is the LAST marker in the source. The editable offset must hit that one.
  if (opts.editableAtLastMarker) {
    const last = source.lastIndexOf("[ ]");
    if (editable.length !== 1 || editable[0].offset !== last) {
      fail(`[${label}] expected single editable offset at real task ${last}, got ${JSON.stringify(editable.map((e) => e.offset))}`);
    }
  }
}

// Shared fixture (nested + blockquote + fenced decoy), under LF and CRLF.
// 7 checkboxes: 5 top-level + 1 nested (now editable) + 1 blockquote (display-only).
check("LF", md.replace(/\r\n/g, "\n"), { minReadonly: 1, minEditable: 6, minRendered: 7 });
check("CRLF", md.replace(/\r\n/g, "\n").replace(/\n/g, "\r\n"), { minReadonly: 1, minEditable: 6, minRendered: 7 });

// Link reference definitions emit no token — offsets must still land on real markers.
check("link-defs", '[ref]: https://example.com "x"\n[a]: https://a.example\n\n- [ ] first\n- [ ] second\n', { minEditable: 2 });

// Adversarial: a link-definition title that contains the exact raw of the real task below.
// Masking the definition block must steer the match to the real task, single- and multi-line.
check("link-def-title-collision", '[r]: https://e "* [ ] task"\n\n* [ ] task\n', { minEditable: 1, editableAtLastMarker: true });
check("link-def-multiline-title-collision", '[r]: https://e "line1\n- [ ] task"\n\n- [ ] task\n', { minEditable: 1, editableAtLastMarker: true });
// Title that begins on the line AFTER the destination, spanning a task-identical line.
check("link-def-nextline-title-collision", '[r]: https://e\n"line1\n- [ ] task"\n\n- [ ] task\n', { minEditable: 1, editableAtLastMarker: true });
// Destination itself on the next line, then a multiline title spanning a task-identical line.
check("link-def-nextline-dest-collision", '[r]:\n  https://e\n  "x\n* [ ] task\n"\n\n* [ ] task\n', { minEditable: 1, editableAtLastMarker: true });
// `<...>` destination and `(...)` title forms.
check("link-def-angle-dest-collision", '[r]: <https://e> "* [ ] task"\n\n* [ ] task\n', { minEditable: 1, editableAtLastMarker: true });
check("link-def-paren-title-collision", '[r]: https://e (* [ ] task)\n\n* [ ] task\n', { minEditable: 1, editableAtLastMarker: true });
// Escaped delimiter inside the title must not be treated as the title's end.
check("link-def-escaped-title-collision", '[r]: https://e "a \\" b\n* [ ] task"\n\n* [ ] task\n', { minEditable: 1, editableAtLastMarker: true });
// A code fence containing a def-look-alike line for a label that IS defined elsewhere must
// not be blanked, or the code token's raw goes unfound and later offsets drift.
check("def-lookalike-inside-fence", '[ref]: https://e\n\n```\n[ref]: x\n- [ ] fake\n```\n\n- [ ] real\n', { minEditable: 1, editableAtLastMarker: true });
// Label with collapsed internal whitespace must normalize to match marked's key and be masked.
check("def-collapsed-label-collision", '[a  b]: https://e "x\n- [ ] task"\n\n- [ ] task\n', { minEditable: 1, editableAtLastMarker: true });

// Plain nested task lists are editable (no blockquote, no code decoy).
check("plain-nested", "- [ ] a\n  - [ ] b\n    - [x] c\n- [ ] d\n", { minEditable: 4, maxEditable: 4 });
// A blockquoted task inside a list can't be located by the scanner, so the WHOLE list is
// display-only (never editable with a wrong offset). Both checkboxes must be display-only.
check("blockquote-task-in-list", "- [ ] parent\n  > - [ ] quoted\n", { minRendered: 2, minReadonly: 2, maxEditable: 0 });
// An indented-code task-look-alike inside a list makes the scan over-count → display-only.
check("indented-code-in-list", "- [ ] real\n\n        - [ ] fake\n", { maxEditable: 0 });

if (!ok) process.exit(1);
console.log("PASS: offsets align and hit real markers across LF/CRLF/link-def cases; nested/blockquote display-only");
