// Proves: with trust:false, KaTeX does NOT emit a javascript: link; with trust:true it does.
const { execSync } = require("node:child_process");
const fs = require("node:fs");
const { mkdtempSync } = fs;
const os = require("node:os");
const path = require("node:path");

// Resolve KaTeX from the repo (portable across clones/CI): prefer the build cache
// tarball, then a built vendor copy. If neither exists, skip rather than hard-fail —
// assert-no-katex-trust.sh is the real regression guard; this is the behavioral proof.
const root = path.resolve(__dirname, "..");
const tgz = path.join(root, ".build", "cache", "katex-0.16.21.tgz");
const vendorKatex = path.join(root, "dist", "QuickMD.app", "Contents", "Resources", "vendor", "katex.min.js");

let katex;
if (fs.existsSync(tgz)) {
  const tmp = mkdtempSync(path.join(os.tmpdir(), "katex-"));
  execSync(`tar -xzf "${tgz}" -C "${tmp}"`);
  katex = require(path.join(tmp, "package", "dist", "katex.js"));
} else if (fs.existsSync(vendorKatex)) {
  katex = require(vendorKatex);
} else {
  console.log("SKIP: KaTeX not available (no .build cache, no built vendor). Run ./build.sh first.");
  process.exit(0);
}

const tex = "\\href{javascript:alert(1)}{x}";
const unsafe = katex.renderToString(tex, { throwOnError: false, trust: true });
const safe = katex.renderToString(tex, { throwOnError: false, trust: false });

// The dangerous output is a CLICKABLE javascript: link, i.e. an href ATTRIBUTE
// pointing at javascript:. (KaTeX always echoes the raw TeX source verbatim
// inside an inert <annotation> text node, so a plain /javascript:/ match would
// false-positive even in the safe case; we must assert on the href attribute.)
const jsHref = /href\s*=\s*(["'])\s*javascript:/i;

if (!jsHref.test(unsafe)) {
  console.error("UNEXPECTED: trust:true did not emit a javascript: href — test assumptions wrong");
  process.exit(2);
}
if (jsHref.test(safe)) {
  console.error("FAIL: trust:false STILL emitted a javascript: href");
  process.exit(1);
}
console.log("PASS: trust:false blocks javascript: href (trust:true would allow it)");
