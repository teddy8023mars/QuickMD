// Mirrors isTaskCheckbox() from src/viewer.js: a GFM task checkbox is the first element of
// an <li> (tight list) or of the <li>'s leading <p> (loose list). Raw HTML <input> anywhere
// else must be excluded so it can't shift the checkbox index mapping. If you change one,
// change both. Uses minimal fake nodes (the function only reads tagName / parentElement /
// firstElementChild), so no DOM library is needed.

function isTaskCheckbox(cb) {
  const parent = cb.parentElement;
  if (!parent || cb !== parent.firstElementChild) return false;
  if (parent.tagName === "LI") return true;
  if (parent.tagName === "P") {
    const li = parent.parentElement;
    return !!li && li.tagName === "LI" && li.firstElementChild === parent;
  }
  return false;
}

// Tiny tree builder: el(tag, ...children) wires parentElement + firstElementChild.
function el(tagName, ...children) {
  const node = { tagName, parentElement: null, firstElementChild: children[0] || null };
  for (const c of children) c.parentElement = node;
  return node;
}

let ok = true;
const assert = (cond, msg) => { if (!cond) { console.error("FAIL: " + msg); ok = false; } };

// tight: <li><input> text</li>
const tight = (() => { const input = el("INPUT"); el("LI", input); return input; })();
assert(isTaskCheckbox(tight), "tight list task checkbox should be editable");

// loose: <li><p><input> text</p></li>
const loose = (() => { const input = el("INPUT"); const p = el("P", input); el("LI", p); return input; })();
assert(isTaskCheckbox(loose), "loose list task checkbox should be editable");

// raw HTML input in a paragraph: <p>text <input></p>  (not first child)
const rawInP = (() => { const lead = el("SPAN"); const input = el("INPUT"); el("P", lead, input); return input; })();
assert(!isTaskCheckbox(rawInP), "raw input not first child of <p> must be excluded");

// raw HTML input as a standalone first child of <p> directly under body (not an <li>)
const rawTopP = (() => { const input = el("INPUT"); const p = el("P", input); el("DIV", p); return input; })();
assert(!isTaskCheckbox(rawTopP), "raw input in a non-list <p> must be excluded");

// raw input that is NOT the li's first element (e.g. <li>text <input></li>)
const rawInLi = (() => { const lead = el("SPAN"); const input = el("INPUT"); el("LI", lead, input); return input; })();
assert(!isTaskCheckbox(rawInLi), "input that isn't the li's first element must be excluded");

if (!ok) process.exit(1);
console.log("PASS: GFM task checkboxes (tight + loose) included; raw HTML inputs excluded");
