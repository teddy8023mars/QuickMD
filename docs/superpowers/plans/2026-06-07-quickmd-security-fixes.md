# QuickMD Security & Correctness Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the two P0 security holes (Quick Look script injection, KaTeX `trust:true` XSS) and the P1 correctness/robustness bugs (checkbox index desync, checkbox writeback race) confirmed by the Codex adversarial review.

**Architecture:** QuickMD is a native macOS app (Objective-C `main.m` + WKWebView) plus a Swift Quick Look extension. Markdown is parsed client-side by marked.js, sanitized by DOMPurify, then enhanced (highlight.js / KaTeX / Mermaid). The main app passes markdown to the WebView as a base64 JSON payload; the Quick Look extension currently does NOT and is the weak point. Fixes are file-isolated so the three tasks can run fully in parallel.

**Tech Stack:** Objective-C (clang, ARC), Swift (swiftc, Xcode), vanilla JS, bash build script. Node 24 available for JS verification. No pre-existing unit-test harness — verification is `node --check` / behavioral Node scripts / `clang -fsyntax-only` / `swiftc -typecheck` / `./build.sh` compile + fixture-based manual smoke tests.

---

## Parallelization Map

The three tasks touch **disjoint files** and can be executed by three parallel subagents (each in its own git worktree). Merge is trivial because there are no overlapping edits.

| Task | Severity | File(s) touched | Depends on |
|------|----------|-----------------|------------|
| Task 1 — KaTeX `trust:true` | P0 | `src/viewer.js`, `test/katex-trust.test.cjs`, `test/assert-no-katex-trust.sh` | none |
| Task 2 — Quick Look base64 payload | P0 | `QuickMDPreview/PreviewViewController.swift`, `test/fixtures/xss-script.md` | none |
| Task 3 — Checkbox index + writeback race | P1 | `src/main.m`, `test/fixtures/checkbox-mix.md` | none |

> Tasks 3's two fixes (#3 index, #7 race) live in the **same Obj-C method** in the same file, so they are ONE task (cannot be split across agents without conflict). Tasks 1, 2, 3 are mutually independent.

**Offline build note:** A fresh worktree will not contain `.build/cache/` (gitignored). Before running `./build.sh` in a worktree, copy the cache so the build stays offline:
`mkdir -p .build && cp -R /Users/teddy/Desktop/QuickMD/.build/cache .build/cache`
The lighter per-file checks (`node --check`, `clang -fsyntax-only`, `swiftc -typecheck`) do NOT need the cache.

---

## File Structure

- `src/viewer.js` — main-app WebView renderer. Only `renderMath()` changes (Task 1).
- `QuickMDPreview/PreviewViewController.swift` — Quick Look renderer. `buildPreviewHTML()` rewritten to a base64 JSON payload; `escapeForJS()` deleted (Task 2).
- `src/main.m` — native app. `userContentController:didReceiveScriptMessage:` rewritten + new helper `taskCheckboxRangesInString:` + new property + `QMDFSEventCallback` self-write suppression (Task 3).
- `test/` — new lightweight verification scripts and fixtures (created by this plan; no framework, just runnable node/bash + sample markdown).

---

## Task 1: Remove KaTeX `trust:true` (P0 XSS)

**Why:** `src/viewer.js` sanitizes marked output with DOMPurify, inserts it, then runs `renderMathInElement(root, { ..., trust: true })` over the live DOM. KaTeX output is NOT re-sanitized, and with `trust:true` a markdown file containing `\href{javascript:alert(1)}{x}` produces a clickable `javascript:` anchor → script execution. Default `trust:false` makes KaTeX ignore `\href`, closing the hole.

**Files:**
- Modify: `src/viewer.js` (function `renderMath`, around lines 476–492 — the `trust: true,` line)
- Create: `test/assert-no-katex-trust.sh` (regression guard)
- Create: `test/katex-trust.test.cjs` (behavioral proof using bundled KaTeX)

- [ ] **Step 1: Write the regression guard (failing test)**

Create `test/assert-no-katex-trust.sh`:

```bash
#!/bin/bash
# Fails if viewer.js still enables KaTeX trust (which allows javascript: hrefs).
set -euo pipefail
if grep -nE 'trust:\s*true' src/viewer.js; then
  echo "FAIL: 'trust: true' present in src/viewer.js (KaTeX XSS risk)"
  exit 1
fi
echo "PASS: no KaTeX trust:true in src/viewer.js"
```

- [ ] **Step 2: Run the guard to verify it FAILS**

Run: `chmod +x test/assert-no-katex-trust.sh && ./test/assert-no-katex-trust.sh`
Expected: prints the matching line and `FAIL: 'trust: true' present...`, exit code 1.

- [ ] **Step 3: Write the behavioral proof test**

Create `test/katex-trust.test.cjs` (extracts the cached KaTeX and asserts the security property directly):

```js
// Proves: with trust:false, KaTeX does NOT emit a javascript: link; with trust:true it does.
const { execSync } = require("node:child_process");
const { mkdtempSync } = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const tgz = path.resolve("/Users/teddy/Desktop/QuickMD/.build/cache/katex-0.16.21.tgz");
const tmp = mkdtempSync(path.join(os.tmpdir(), "katex-"));
execSync(`tar -xzf "${tgz}" -C "${tmp}"`);
const katex = require(path.join(tmp, "package", "dist", "katex.js"));

const tex = "\\href{javascript:alert(1)}{x}";
const unsafe = katex.renderToString(tex, { throwOnError: false, trust: true });
const safe = katex.renderToString(tex, { throwOnError: false, trust: false });

if (!/javascript:/i.test(unsafe)) {
  console.error("UNEXPECTED: trust:true did not emit javascript: link — test assumptions wrong");
  process.exit(2);
}
if (/javascript:/i.test(safe)) {
  console.error("FAIL: trust:false STILL emitted a javascript: link");
  process.exit(1);
}
console.log("PASS: trust:false blocks javascript: href (trust:true would allow it)");
```

- [ ] **Step 4: Run the behavioral test to confirm the assumption**

Run: `node test/katex-trust.test.cjs`
Expected: `PASS: trust:false blocks javascript: href ...`, exit code 0. (This confirms removing `trust:true` is the correct fix.)

- [ ] **Step 5: Apply the fix in `src/viewer.js`**

In `renderMath`, delete the `trust: true,` line so the options become:

```js
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
```

- [ ] **Step 6: Run both checks to verify they PASS**

Run: `node --check src/viewer.js && ./test/assert-no-katex-trust.sh && node test/katex-trust.test.cjs`
Expected: `node --check` silent (valid JS); `PASS: no KaTeX trust:true...`; `PASS: trust:false blocks...`. All exit 0.

- [ ] **Step 7: Commit**

```bash
git add src/viewer.js test/assert-no-katex-trust.sh test/katex-trust.test.cjs
git commit -m "fix(security): disable KaTeX trust to block javascript: href XSS"
```

---

## Task 2: Quick Look — pass markdown as base64 JSON payload (P0 injection)

**Why:** `QuickMDPreview/PreviewViewController.swift` interpolates the markdown (via `escapeForJS`) into an inline `<script>` string literal. `escapeForJS` never neutralizes `<`/`</script>`, so a `.md` file containing literal `</script><script>…</script>` closes the script tag during HTML parsing and runs attacker-controlled JS before DOMPurify ever sees it. The main app already avoids this with a base64 JSON payload; mirror that. Base64 output only contains `[A-Za-z0-9+/=]`, so it cannot break out of the JSON string or the script/HTML context. Also stop interpolating the raw `filename` into `<title>` (filenames may contain `<`/`>`).

**Files:**
- Modify: `QuickMDPreview/PreviewViewController.swift` (rewrite `buildPreviewHTML`, delete `escapeForJS`)
- Create: `test/fixtures/xss-script.md` (manual smoke fixture)

- [ ] **Step 1: Create the attack fixture (the "failing test" input)**

Create `test/fixtures/xss-script.md`:

```markdown
# Quick Look XSS Probe

Normal paragraph above.

</script><script>document.title = "PWNED";</script>

- list item after the probe
```

- [ ] **Step 2: Establish the failing baseline (manual, current code)**

Build current code and Quick Look the fixture:
Run: `cp -R /Users/teddy/Desktop/QuickMD/.build/cache .build/cache 2>/dev/null; ./build.sh`
Then in Finder select `test/fixtures/xss-script.md` and press Space (or `qlmanage -p test/fixtures/xss-script.md`).
Expected (current/buggy): the document title becomes `PWNED` and/or the heading fails to render — proving injection. Record this as the baseline to fix.

> If swiftc/Xcode is unavailable the build prints "Skipping Quick Look extension"; in that case skip the manual smoke and rely on Steps 5–6 static checks.

- [ ] **Step 3: Rewrite `buildPreviewHTML` to use a base64 JSON payload**

Replace the entire `buildPreviewHTML(markdown:filename:baseURL:)` body. Key changes: base64-encode `markdown` and `filename`; emit them in a `<script type="application/json">` tag; decode + render in the inline script; HTML is built without ever placing raw markdown in executable position.

```swift
    private func buildPreviewHTML(markdown: String, filename: String, baseURL: URL) -> String {
        let markdownB64 = Data(markdown.utf8).base64EncodedString()
        let filenameB64 = Data(filename.utf8).base64EncodedString()

        // Load JS libraries from bundle (offline, no network needed)
        let markedJS = loadBundledResource("marked.min.js")
        let purifyJS = loadBundledResource("purify.min.js")
        let highlightJS = loadBundledResource("highlight.min.js")
        let katexJS = loadBundledResource("katex.min.js")
        let autoRenderJS = loadBundledResource("auto-render.min.js")
        let katexCSS = loadBundledResource("katex.min.css")

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <base href="\(baseURL.absoluteString)">
        <title>QuickMD Preview</title>
        <style>\(katexCSS)</style>
        <style>
        :root {
            --bg: #ffffff;
            --fg: #1f2328;
            --code-bg: #f6f8fa;
            --code-fg: #1f2328;
            --border: #d0d7de;
            --link: #0969da;
            --blockquote-border: #d0d7de;
            --blockquote-fg: #656d76;
            --table-header-bg: #f6f8fa;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --bg: #1a1b26;
                --fg: #c0caf5;
                --code-bg: #24283b;
                --code-fg: #c0caf5;
                --border: #3b4261;
                --link: #7aa2f7;
                --blockquote-border: #3b4261;
                --blockquote-fg: #9aa5ce;
                --table-header-bg: #24283b;
            }
        }
        * { box-sizing: border-box; }
        html, body { background: var(--bg); }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
            font-size: 15px;
            line-height: 1.7;
            color: var(--fg);
            margin: 0;
            padding: 24px 40px;
            max-width: 900px;
            opacity: 0;
            transition: opacity 0.15s ease-in;
        }
        body.ready { opacity: 1; }
        h1, h2, h3, h4, h5, h6 { margin-top: 1.5em; margin-bottom: 0.5em; font-weight: 600; color: var(--fg); }
        h1 { font-size: 2em; border-bottom: 1px solid var(--border); padding-bottom: 0.3em; }
        h2 { font-size: 1.5em; border-bottom: 1px solid var(--border); padding-bottom: 0.3em; }
        h3 { font-size: 1.25em; }
        a { color: var(--link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        code {
            font-family: "SF Mono", "Fira Code", Menlo, Consolas, monospace;
            font-size: 0.9em;
            background: var(--code-bg);
            color: var(--code-fg);
            padding: 0.2em 0.4em;
            border-radius: 4px;
        }
        pre {
            background: var(--code-bg);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 16px;
            overflow-x: auto;
            line-height: 1.5;
        }
        pre code { background: none; padding: 0; font-size: 0.85em; color: var(--code-fg); }
        blockquote {
            margin: 1em 0;
            padding: 0.5em 1em;
            border-left: 4px solid var(--blockquote-border);
            color: var(--blockquote-fg);
            background: transparent;
        }
        table { border-collapse: collapse; width: 100%; margin: 1em 0; }
        th, td { border: 1px solid var(--border); padding: 8px 12px; text-align: left; }
        th { background: var(--table-header-bg); font-weight: 600; }
        img { max-width: 100%; height: auto; border-radius: 4px; }
        hr { border: none; border-top: 1px solid var(--border); margin: 2em 0; }
        ul, ol { padding-left: 2em; }
        li { margin: 0.3em 0; }
        input[type="checkbox"] {
            -webkit-appearance: none;
            appearance: none;
            width: 16px;
            height: 16px;
            border: 1.5px solid var(--border);
            border-radius: 3px;
            background: var(--bg);
            vertical-align: middle;
            margin-right: 0.5em;
            position: relative;
            top: -1px;
            pointer-events: none;
        }
        input[type="checkbox"]:checked { background: var(--link); border-color: var(--link); }
        input[type="checkbox"]:checked::after {
            content: '';
            position: absolute;
            left: 4px;
            top: 1px;
            width: 5px;
            height: 9px;
            border: solid white;
            border-width: 0 2px 2px 0;
            transform: rotate(45deg);
        }
        .task-list-item { list-style: none; margin-left: -1.5em; }
        </style>
        </head>
        <body>
        <div id="content"></div>
        <script id="viewer-data" type="application/json">{"markdown":"\(markdownB64)","filename":"\(filenameB64)"}</script>
        <script>\(markedJS)</script>
        <script>\(purifyJS)</script>
        <script>\(highlightJS)</script>
        <script>\(katexJS)</script>
        <script>\(autoRenderJS)</script>
        <script>
        (function() {
            function decodeB64(value) {
                const binary = atob(value || "");
                const bytes = new Uint8Array(binary.length);
                for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
                return new TextDecoder().decode(bytes);
            }
            try {
                const payload = JSON.parse(document.getElementById('viewer-data').textContent);
                const markdown = decodeB64(payload.markdown);
                document.title = decodeB64(payload.filename);
                marked.setOptions({ gfm: true, breaks: false, pedantic: false });
                const rawHtml = marked.parse(markdown);
                const cleanHtml = DOMPurify.sanitize(rawHtml, {
                    ADD_TAGS: ['input'],
                    ADD_ATTR: ['type', 'checked', 'disabled', 'class'],
                    ALLOW_DATA_ATTR: true
                });
                const contentEl = document.getElementById('content');
                contentEl.innerHTML = cleanHtml;
                if (window.hljs) {
                    const blocks = contentEl.querySelectorAll('pre code');
                    for (const block of blocks) window.hljs.highlightElement(block);
                }
                if (window.renderMathInElement) {
                    renderMathInElement(contentEl, {
                        delimiters: [
                            { left: '$$', right: '$$', display: true },
                            { left: '$', right: '$', display: false },
                            { left: '\\\\[', right: '\\\\]', display: true },
                            { left: '\\\\(', right: '\\\\)', display: false }
                        ],
                        throwOnError: false
                    });
                }
                document.body.classList.add('ready');
            } catch (e) {
                document.getElementById('content').textContent = 'Error: ' + e.message;
                document.body.classList.add('ready');
            }
        })();
        </script>
        </body>
        </html>
        """
    }
```

- [ ] **Step 4: Delete the now-unused `escapeForJS` function**

Remove the entire `private func escapeForJS(_ string: String) -> String { ... }` method (the last method in the file). It has no remaining callers after Step 3.

- [ ] **Step 5: Static checks — no raw markdown in executable position**

Run:
```bash
grep -n 'escapeForJS' QuickMDPreview/PreviewViewController.swift || echo "OK: escapeForJS removed"
grep -n 'viewer-data' QuickMDPreview/PreviewViewController.swift && echo "OK: base64 payload present"
grep -nE '\\\(escapedMarkdown\)|\\\(markdown\)' QuickMDPreview/PreviewViewController.swift || echo "OK: no raw markdown interpolation"
```
Expected: `OK: escapeForJS removed`, `OK: base64 payload present`, `OK: no raw markdown interpolation`.

- [ ] **Step 6: Compile-check the Swift file (if Xcode present)**

Run: `swiftc -typecheck -sdk "$(xcrun --show-sdk-path)" QuickMDPreview/PreviewViewController.swift`
Expected: no errors. (If swiftc is unavailable, note it and rely on `./build.sh` during integration.)

- [ ] **Step 7: Re-run the attack fixture to verify the fix**

Run: `./build.sh` then `qlmanage -p test/fixtures/xss-script.md` (or Finder Space).
Expected: heading "Quick Look XSS Probe" renders, the `</script>...` line shows as literal text (or is stripped), and the document title is the filename `xss-script.md`, NOT `PWNED`.

- [ ] **Step 8: Commit**

```bash
git add QuickMDPreview/PreviewViewController.swift test/fixtures/xss-script.md
git commit -m "fix(security): pass markdown to Quick Look as base64 payload to stop script injection"
```

---

## Task 3: Fix checkbox index desync (#3) and writeback race (#7) (P1)

**Why (#3):** `viewer.js` numbers every rendered `input[type="checkbox"]`; `main.m` maps that index onto matches of the unanchored regex `- \[([ xX])\]`. Marked also renders `* [ ]`, `+ [ ]`, and `1. [ ]` task items as checkboxes, and the unanchored pattern also matches checkbox-looking text inside fenced code blocks. Either makes the index point at the wrong source line, so toggling rewrites a different task — or code — than the one clicked.

**Why (#7):** The writeback does read → regex-edit → `stopWatching` → `writeToURL:...error:nil` → restart watching after a fixed 2 s. It ignores write errors, can clobber a concurrent external edit (stale read-modify-write), and drops external edits that land inside the 2 s blind window.

**Fix approach:** (a) Derive editable checkbox source ranges line-by-line, skipping fenced code blocks, matching `-`/`*`/`+`/ordered task markers — matching what marked renders. (b) Replace the blind stop/2 s-restart with content-based self-write suppression: re-read just before writing to abort on external change, handle write errors, and have the FSEvent callback skip the reload when the file content equals what we just wrote.

**Files:**
- Modify: `src/main.m` — add property, add helper, rewrite `userContentController:didReceiveScriptMessage:`, update `QMDFSEventCallback`
- Create: `test/fixtures/checkbox-mix.md` (manual smoke fixture)

- [ ] **Step 1: Create the mixed-checkbox fixture**

Create `test/fixtures/checkbox-mix.md`:

````markdown
# Checkbox Index Test

- [ ] dash zero
* [ ] star one
+ [ ] plus two
1. [ ] ordered three

```text
- [ ] DECOY inside code fence (must NOT count)
```

- [ ] dash four
````

Rendered, marked shows 5 interactive checkboxes (indices 0–4): "dash zero", "star one", "plus two", "ordered three", "dash four". The DECOY line is inside a fence and must be ignored.

- [ ] **Step 2: Add the self-write tracking property**

In the `@interface QMDPreviewWindowController (...)` property block (near `main.m:42`, after `pendingTOCVisible`), add:

```objc
@property(nonatomic, copy) NSString *expectedSelfWriteContent;
```

- [ ] **Step 3: Add the `taskCheckboxRangesInString:` helper**

Add this method to the `QMDPreviewWindowController` implementation (e.g. just above `userContentController:didReceiveScriptMessage:`):

```objc
// Returns the source NSRange of each editable task checkbox marker ("[ ]" / "[x]"),
// in render order, skipping fenced code blocks. Matches -, *, +, and ordered list markers,
// mirroring what marked.js renders as an interactive checkbox.
- (NSArray<NSValue *> *)taskCheckboxRangesInString:(NSString *)content {
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    NSRegularExpression *lineRegex =
        [NSRegularExpression regularExpressionWithPattern:@"^[ \\t]*(?:[-*+]|\\d+[.)])\\s+(\\[[ xX]\\])"
                                                  options:0
                                                    error:nil];
    __block BOOL inFence = NO;
    [content enumerateSubstringsInRange:NSMakeRange(0, content.length)
                               options:NSStringEnumerationByLines
                            usingBlock:^(NSString *line, NSRange lineRange, NSRange enclosingRange, BOOL *stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([trimmed hasPrefix:@"```"] || [trimmed hasPrefix:@"~~~"]) { inFence = !inFence; return; }
        if (inFence) return;
        NSTextCheckingResult *m = [lineRegex firstMatchInString:line
                                                        options:0
                                                          range:NSMakeRange(0, line.length)];
        if (!m) return;
        NSRange boxInLine = [m rangeAtIndex:1]; // the "[ ]" / "[x]"
        NSRange boxInContent = NSMakeRange(lineRange.location + boxInLine.location, boxInLine.length);
        [ranges addObject:[NSValue valueWithRange:boxInContent]];
    }];
    return ranges;
}
```

- [ ] **Step 4: Rewrite the message handler body**

Replace the body of `userContentController:didReceiveScriptMessage:` (currently `main.m:453–496`) from the `// Find the Nth task list checkbox...` comment onward with index lookup via the helper, a stale-write guard, error handling, and self-write suppression (no more stop/2 s-restart):

```objc
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"checkboxToggle"]) return;
    if (![message.body isKindOfClass:[NSDictionary class]]) return;

    NSDictionary *body = (NSDictionary *)message.body;
    NSInteger checkboxIndex = [body[@"index"] integerValue];
    BOOL checked = [body[@"checked"] boolValue];

    if (!self.sourceFileURL) return;

    NSError *readError = nil;
    NSString *content = [NSString stringWithContentsOfURL:self.sourceFileURL
                                                encoding:NSUTF8StringEncoding
                                                   error:&readError];
    if (readError || !content) return;

    NSArray<NSValue *> *boxes = [self taskCheckboxRangesInString:content];
    if (checkboxIndex < 0 || checkboxIndex >= (NSInteger)boxes.count) return;

    NSRange boxRange = [boxes[checkboxIndex] rangeValue];
    NSString *replacement = checked ? @"[x]" : @"[ ]";

    NSMutableString *mutableContent = [content mutableCopy];
    [mutableContent replaceCharactersInRange:boxRange withString:replacement];

    // Stale-write guard: if the file changed on disk since we rendered, reload instead of clobbering.
    NSString *latest = [NSString stringWithContentsOfURL:self.sourceFileURL
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
    if (latest && ![latest isEqualToString:content]) {
        [self reloadPreview:nil];
        return;
    }

    // Record what we are about to write so the FSEvent callback can ignore our own change.
    self.expectedSelfWriteContent = mutableContent;

    NSError *writeError = nil;
    if (![mutableContent writeToURL:self.sourceFileURL
                         atomically:YES
                           encoding:NSUTF8StringEncoding
                              error:&writeError]) {
        self.expectedSelfWriteContent = nil; // write failed; let future events reload normally
        return;
    }
}
```

- [ ] **Step 5: Suppress the self-write in the FSEvent callback**

In `QMDFSEventCallback` (`main.m:339–356`), before calling `[controller reloadPreview:nil]` for a matched file, skip the reload when the on-disk content equals the content we just wrote:

```objc
        if ([changedName isEqualToString:watchedName]) {
            if (controller.expectedSelfWriteContent) {
                NSString *current = [NSString stringWithContentsOfURL:controller.sourceFileURL
                                                            encoding:NSUTF8StringEncoding
                                                               error:nil];
                if (current && [current isEqualToString:controller.expectedSelfWriteContent]) {
                    controller.expectedSelfWriteContent = nil; // our own write; nothing to reload
                    return;
                }
            }
            [controller reloadPreview:nil];
            return;
        }
```

- [ ] **Step 6: Static checks**

Run:
```bash
grep -n 'taskCheckboxRangesInString' src/main.m && echo "OK: helper present"
grep -n 'expectedSelfWriteContent' src/main.m && echo "OK: self-write tracking present"
grep -n 'dispatch_after' src/main.m || echo "OK: blind 2s re-watch removed"
```
Expected: helper present, self-write tracking present (≥3 references), and no `dispatch_after` remaining in the checkbox path (`OK: blind 2s re-watch removed`).

- [ ] **Step 7: Compile-check `main.m`**

Run:
```bash
clang -fsyntax-only -fobjc-arc \
  -framework Cocoa -framework WebKit -framework CoreServices -framework UniformTypeIdentifiers \
  src/main.m
```
Expected: no output, exit 0 (compiles cleanly).

- [ ] **Step 8: Manual smoke — correct line toggles**

Run: `cp -R /Users/teddy/Desktop/QuickMD/.build/cache .build/cache 2>/dev/null; ./build.sh && open -a "$(pwd)/dist/QuickMD.app" test/fixtures/checkbox-mix.md`
In the preview, click the **3rd** checkbox ("plus two"). Then open `test/fixtures/checkbox-mix.md` in a text editor.
Expected: the `+ [ ]` line became `+ [x]`; the DECOY line inside the code fence is unchanged; no other line changed. Repeat for the ordered item ("ordered three") → `1. [x]`.

- [ ] **Step 9: Commit**

```bash
git add src/main.m test/fixtures/checkbox-mix.md
git commit -m "fix: correct task-checkbox source mapping and harden writeback against races"
```

---

## Integration (after all three tasks merge)

- [ ] **Step 1: Full clean build with all fixes**

Run: `cp -R /Users/teddy/Desktop/QuickMD/.build/cache .build/cache 2>/dev/null; ./build.sh`
Expected: build succeeds; main app and (if Xcode present) `QuickMDPreview.appex` are produced under `dist/QuickMD.app`.

- [ ] **Step 2: Run all JS checks**

Run: `node --check src/viewer.js && ./test/assert-no-katex-trust.sh && node test/katex-trust.test.cjs`
Expected: all PASS.

- [ ] **Step 3: Re-run both fixtures end-to-end**

`qlmanage -p test/fixtures/xss-script.md` → title is `xss-script.md`, not `PWNED`.
`open -a "$(pwd)/dist/QuickMD.app" test/fixtures/checkbox-mix.md` → toggling maps to the right source lines, fence decoy ignored.

- [ ] **Step 4: Final commit if any integration tweaks were needed**

```bash
git add -A && git commit -m "test: QuickMD security/correctness fixes integration verification"
```

---

## Self-Review Notes

- **Spec coverage:** Codex P0 #1 (Task 2), P0 #2 (Task 1), P1 #3 (Task 3 steps 3–4), P1 #7 (Task 3 steps 4–5). Deferred per Codex: #4 (search perf), #5 (renderer divergence — partially mitigated since Quick Look now mirrors the base64 pattern), #6 (unused Mermaid copy). These are intentionally out of scope.
- **No placeholders:** every code step shows the full replacement code; every run step has an exact command and expected output.
- **Type/name consistency:** `taskCheckboxRangesInString:` returns `NSArray<NSValue *>` of `NSRange`, consumed in Step 4 via `rangeValue`; `expectedSelfWriteContent` property is set in the handler and read/cleared in `QMDFSEventCallback`; `decodeB64` defined and used within the same inline script in Task 2.
- **Native-test caveat:** there is no XCTest harness; native verification is compile-check + `./build.sh` + fixture smoke tests, which is appropriate for this single-binary app and matches its existing (test-free) structure.
