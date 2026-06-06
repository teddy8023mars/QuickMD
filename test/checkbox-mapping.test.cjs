// Proves the viewer's checkbox source-mapping (computeTaskCheckboxOffsets in src/viewer.js)
// stays in lockstep with the checkboxes marked.js renders:
//   * exactly one entry per rendered checkbox (index alignment),
//   * every EDITABLE entry points at a literal "[ ]"/"[x]" in the source,
//   * nested-list and blockquote checkboxes are non-editable (offset === null),
//     because marked normalizes their child token raws so offsets can't be trusted.
// This mirror MUST match the walk in src/viewer.js. If you change one, change both.
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const marked = require(path.join(root, "QuickMDPreview", "vendor", "marked.min.js"));
const md = fs.readFileSync(path.join(root, "test", "fixtures", "checkbox-mix.md"), "utf8");

function computeTaskCheckboxOffsets(markdown) {
  const out = [];
  const tokens = marked.lexer(markdown);
  const walk = (toks, base, editable) => {
    for (const token of toks) {
      if (token.type === "list") {
        let itemBase = base;
        for (const item of token.items) {
          if (item.task) {
            const m = editable ? /\[[ xX]\]/.exec(item.raw) : null;
            out.push({ offset: m ? itemBase + m.index : null });
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

const entries = computeTaskCheckboxOffsets(md);
const html = marked.parse(md);
const rendered = (html.match(/<input[^>]*type="checkbox"/g) || []).length;

let ok = true;
const fail = (msg) => { console.error("FAIL: " + msg); ok = false; };

console.log(`rendered checkboxes: ${rendered}, entries: ${entries.length}`);
if (rendered !== entries.length) fail(`entry count ${entries.length} != rendered ${rendered} — would desync`);

const editable = entries.filter((e) => e.offset != null);
const readonly = entries.length - editable.length;
console.log(`editable: ${editable.length}, display-only: ${readonly}`);

for (const e of editable) {
  const marker = md.substr(e.offset, 3);
  if (!/^\[[ xX]\]$/.test(marker)) fail(`editable offset ${e.offset} points at ${JSON.stringify(marker)}, not a checkbox`);
}

// The fixture deliberately includes one nested and one blockquoted task → both display-only.
if (readonly < 2) fail(`expected >=2 display-only checkboxes (nested + blockquote), got ${readonly}`);
if (rendered < 7) fail(`fixture should exercise >=7 checkboxes, got ${rendered}`);

if (!ok) process.exit(1);
console.log("PASS: offsets align with rendered checkboxes; editable ones hit real markers; nested/blockquote are display-only");
