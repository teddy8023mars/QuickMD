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

  const maskLinkDefinitions = (text, links) => {
    if (!links) return text;
    const labels = new Set(Object.keys(links).map((l) => l.toLowerCase()));
    if (!labels.size) return text;
    const lines = text.split("\n");
    const defOpen = /^ {0,3}\[([^\]]+)\]:\s*(.*)$/;
    let closing = null;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (closing !== null) {
        const hit = line.indexOf(closing) >= 0;
        lines[i] = " ".repeat(line.length);
        if (hit) closing = null;
        continue;
      }
      const m = defOpen.exec(line);
      if (!m || !labels.has(m[1].trim().toLowerCase())) continue;
      lines[i] = " ".repeat(line.length);
      const tail = m[2];
      const opener = /(^|\s)(["'(])/.exec(tail);
      if (opener) {
        const delim = opener[2] === "(" ? ")" : opener[2];
        if (tail.slice(opener.index + opener[0].length).indexOf(delim) < 0) closing = delim;
      }
    }
    return lines.join("\n");
  };
  const searchSpace = maskLinkDefinitions(lf, tokens.links);

  const countNonEditable = (toks) => {
    for (const token of toks) {
      if (token.type === "list") {
        for (const item of token.items) {
          if (item.task) out.push({ offset: null });
          if (item.tokens) countNonEditable(item.tokens);
        }
      } else if (token.type === "blockquote") {
        if (token.tokens) countNonEditable(token.tokens);
      }
    }
  };

  let cursor = 0;
  for (const token of tokens) {
    let base = -1;
    for (let from = cursor; ; ) {
      const idx = searchSpace.indexOf(token.raw, from);
      if (idx < 0) break;
      if (idx === 0 || searchSpace[idx - 1] === "\n") { base = idx; break; }
      from = idx + 1;
    }
    if (base < 0) base = cursor;
    if (token.type === "list") {
      let itemBase = base;
      for (const item of token.items) {
        if (item.task) {
          const m = /\[[ xX]\]/.exec(item.raw);
          out.push({ offset: m ? lfToOrig[itemBase + m.index] : null });
        }
        if (item.tokens) countNonEditable(item.tokens);
        itemBase += item.raw.length;
      }
    } else if (token.type === "blockquote") {
      if (token.tokens) countNonEditable(token.tokens);
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
check("LF", md.replace(/\r\n/g, "\n"), { minReadonly: 2, minRendered: 7 });
check("CRLF", md.replace(/\r\n/g, "\n").replace(/\n/g, "\r\n"), { minReadonly: 2, minRendered: 7 });

// Link reference definitions emit no token — offsets must still land on real markers.
check("link-defs", '[ref]: https://example.com "x"\n[a]: https://a.example\n\n- [ ] first\n- [ ] second\n', { minEditable: 2 });

// Adversarial: a link-definition title that contains the exact raw of the real task below.
// Masking the definition block must steer the match to the real task, single- and multi-line.
check("link-def-title-collision", '[r]: https://e "* [ ] task"\n\n* [ ] task\n', { minEditable: 1, editableAtLastMarker: true });
check("link-def-multiline-title-collision", '[r]: https://e "line1\n- [ ] task"\n\n- [ ] task\n', { minEditable: 1, editableAtLastMarker: true });

if (!ok) process.exit(1);
console.log("PASS: offsets align and hit real markers across LF/CRLF/link-def cases; nested/blockquote display-only");
