// Proves the native checkbox source-matcher (taskCheckboxRangesInString:) stays in
// lockstep with the interactive checkboxes marked.js renders — including blockquoted
// task items and excluding fenced-code decoys. Replicates the Obj-C matcher logic in JS
// and compares its count to marked's rendered checkbox count for the shared fixture.
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const marked = require(path.join(root, "QuickMDPreview", "vendor", "marked.min.js"));
const md = fs.readFileSync(path.join(root, "test", "fixtures", "checkbox-mix.md"), "utf8");

// What the renderer actually produces (the source of truth for indexing).
const html = marked.parse(md);
const rendered = (html.match(/<input[^>]*type="checkbox"/g) || []).length;

// Mirror of src/main.m taskCheckboxRangesInString:
const lineRegex = /^[ \t]*(?:>[ \t]*)*(?:[-*+]|\d+[.)])\s+(\[[ xX]\])/;
let inFence = false;
let matched = 0;
for (const line of md.split(/\r?\n/)) {
  let trimmed = line.trim();
  while (trimmed.startsWith(">")) trimmed = trimmed.slice(1).trim();
  if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) { inFence = !inFence; continue; }
  if (inFence) continue;
  if (lineRegex.test(line)) matched++;
}

console.log(`rendered checkboxes: ${rendered}, matcher found: ${matched}`);
if (rendered !== matched) {
  console.error(`FAIL: matcher (${matched}) != rendered checkboxes (${rendered}) — index will desync`);
  process.exit(1);
}
if (rendered < 6) {
  console.error(`FAIL: fixture should exercise >=6 checkboxes (incl. blockquote), got ${rendered}`);
  process.exit(1);
}
console.log("PASS: native matcher count matches marked's rendered checkboxes (blockquote incl., fence decoy excl.)");
