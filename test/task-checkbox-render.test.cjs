// Verifies the marked renderer override from src/viewer.js tags ONLY GFM task-list
// checkboxes with data-qmd-task, while raw HTML <input> in the document is passed through
// untagged. enableTaskCheckboxes selects by that tag, so a raw input — even one written as
// the first element of an <li> — can no longer be miscounted as a task and disable the real
// task checkboxes. This mirrors configureMarked()'s override; change both together.
const path = require("node:path");
const marked = require(path.resolve(__dirname, "..", "QuickMDPreview", "vendor", "marked.min.js"));

marked.setOptions({ gfm: true, breaks: false, pedantic: false });
marked.use({
  renderer: {
    checkbox(arg) {
      const checked = typeof arg === "object" && arg !== null ? arg.checked : arg;
      return `<input data-qmd-task="" ${checked ? 'checked="" ' : ""}disabled="" type="checkbox"> `;
    },
  },
});

let ok = true;
const fail = (m) => { console.error("FAIL: " + m); ok = false; };
const tagged = (html) => (html.match(/data-qmd-task/g) || []).length;
const inputs = (html) => (html.match(/<input\b/g) || []).length;

function check(label, md, expectedTasks, expectedRawInputs) {
  const html = marked.parse(md);
  const t = tagged(html);
  const total = inputs(html);
  console.log(`[${label}] inputs=${total} tagged(task)=${t} raw=${total - t}`);
  if (t !== expectedTasks) fail(`[${label}] expected ${expectedTasks} task checkboxes, tagged ${t}`);
  if (total - t !== expectedRawInputs) fail(`[${label}] expected ${expectedRawInputs} raw inputs, got ${total - t}`);
}

check("plain tasks", "- [ ] a\n- [x] b\n", 2, 0);
check("loose tasks", "- [ ] a\n\n- [ ] b\n", 2, 0);
check("task + raw in paragraph", "- [ ] a\n\nraw <input type=\"checkbox\"> x\n", 1, 1);
// The Codex round-11 case: a raw HTML checkbox as the first element of an <li>.
check("task + raw list input", "- [ ] real\n\n<ul><li><input type=\"checkbox\"> raw</li></ul>\n", 1, 1);

if (!ok) process.exit(1);
console.log("PASS: only GFM task checkboxes are tagged; raw HTML inputs (incl. in <li>) are not");
