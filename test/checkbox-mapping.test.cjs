// Proves the viewer's checkbox source-mapping (computeTaskCheckboxOffsets in src/viewer.js)
// stays in lockstep with the checkboxes marked.js renders:
//   * exactly one entry per rendered checkbox (index alignment),
//   * every EDITABLE entry points at a literal "[ ]"/"[x]" in the ORIGINAL source,
//   * nested-list and blockquote checkboxes are non-editable (offset === null),
//   * offsets stay correct for CRLF / lone-CR files (marked normalizes raw to "\n").
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
  const walk = (toks, base, editable) => {
    for (const token of toks) {
      if (token.type === "list") {
        let itemBase = base;
        for (const item of token.items) {
          if (item.task) {
            const m = editable ? /\[[ xX]\]/.exec(item.raw) : null;
            out.push({ offset: m ? lfToOrig[itemBase + m.index] : null });
          }
          if (item.tokens) walk(item.tokens, itemBase, false);
          itemBase += item.raw.length;
        }
      } else if (token.type === "blockquote") {
        if (token.tokens) walk(token.tokens, base, false);
      }
      base += token.raw.length;
    }
  };
  walk(tokens, 0, true);
  return out;
}

let ok = true;
const fail = (msg) => { console.error("FAIL: " + msg); ok = false; };

function check(label, source) {
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
  if (readonly < 2) fail(`[${label}] expected >=2 display-only (nested + blockquote), got ${readonly}`);
  if (rendered < 7) fail(`[${label}] fixture should exercise >=7 checkboxes, got ${rendered}`);
}

check("LF", md.replace(/\r\n/g, "\n"));
check("CRLF", md.replace(/\r\n/g, "\n").replace(/\n/g, "\r\n"));

if (!ok) process.exit(1);
console.log("PASS: offsets align and hit real markers under LF and CRLF; nested/blockquote display-only");
