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
    const found = lf.indexOf(token.raw, cursor);
    const base = found >= 0 ? found : cursor;
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
}

// Shared fixture (nested + blockquote + fenced decoy), under LF and CRLF.
check("LF", md.replace(/\r\n/g, "\n"), { minReadonly: 2, minRendered: 7 });
check("CRLF", md.replace(/\r\n/g, "\n").replace(/\n/g, "\r\n"), { minReadonly: 2, minRendered: 7 });

// Link reference definitions emit no token — offsets must still land on real markers.
check("link-defs", '[ref]: https://example.com "x"\n[a]: https://a.example\n\n- [ ] first\n- [ ] second\n', { minEditable: 2 });

if (!ok) process.exit(1);
console.log("PASS: offsets align and hit real markers across LF/CRLF/link-def cases; nested/blockquote display-only");
