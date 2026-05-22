import Cocoa
import Quartz
import WebKit
import QuickLook
import UniformTypeIdentifiers

class PreviewViewController: NSViewController, QLPreviewingController {

    private var webView: WKWebView!

    override var nibName: NSNib.Name? {
        return nil
    }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.autoresizingMask = [.width, .height]
        // Prevent white flash by setting opaque to false
        webView.setValue(false, forKey: "drawsBackground")
        self.view = webView
    }

    // MARK: - QLPreviewingController (callback-based, macOS 10.15+)

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            let markdown = try String(contentsOf: url, encoding: .utf8)
            let baseURL = url.deletingLastPathComponent()
            let html = buildPreviewHTML(markdown: markdown, filename: url.lastPathComponent, baseURL: baseURL)
            webView.loadHTMLString(html, baseURL: baseURL)
            // Give WebView time to render
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                handler(nil)
            }
        } catch {
            handler(error)
        }
    }

    // MARK: - Load bundled JS/CSS resources

    private func loadBundledResource(_ filename: String) -> String {
        let bundle = Bundle(for: PreviewViewController.self)
        // Try with subdirectory first
        if let url = bundle.url(forResource: filename, withExtension: nil, subdirectory: "vendor") {
            return (try? String(contentsOf: url, encoding: .utf8)) ?? "/* failed to read \(filename) */"
        }
        // Try without subdirectory
        if let url = bundle.url(forResource: filename, withExtension: nil) {
            return (try? String(contentsOf: url, encoding: .utf8)) ?? "/* failed to read \(filename) */"
        }
        // Try splitting name and extension
        let parts = filename.split(separator: ".", maxSplits: 1)
        if parts.count == 2, let url = bundle.url(forResource: String(parts[0]), withExtension: String(parts[1]), subdirectory: "vendor") {
            return (try? String(contentsOf: url, encoding: .utf8)) ?? "/* failed to read \(filename) */"
        }
        return "/* \(filename) not found in bundle */"
    }

    // MARK: - HTML Generation

    private func buildPreviewHTML(markdown: String, filename: String, baseURL: URL) -> String {
        let escapedMarkdown = escapeForJS(markdown)

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
        <title>\(filename)</title>
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
        html, body {
            background: var(--bg);
        }
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
        body.ready {
            opacity: 1;
        }
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
        /* Custom checkbox styling to prevent flicker */
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
        input[type="checkbox"]:checked {
            background: var(--link);
            border-color: var(--link);
        }
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
        <script>\(markedJS)</script>
        <script>\(purifyJS)</script>
        <script>\(highlightJS)</script>
        <script>\(katexJS)</script>
        <script>\(autoRenderJS)</script>
        <script>
        (function() {
            try {
                const markdown = "\(escapedMarkdown)";
                marked.setOptions({ gfm: true, breaks: false, pedantic: false });
                const rawHtml = marked.parse(markdown);
                const cleanHtml = DOMPurify.sanitize(rawHtml, {
                    ADD_TAGS: ['input'],
                    ADD_ATTR: ['type', 'checked', 'disabled', 'class'],
                    ALLOW_DATA_ATTR: true
                });
                const contentEl = document.getElementById('content');
                contentEl.innerHTML = cleanHtml;
                // Highlight code blocks
                if (window.hljs) {
                    const blocks = contentEl.querySelectorAll('pre code');
                    for (const block of blocks) window.hljs.highlightElement(block);
                }
                // Render math
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
                // Show content after rendering is complete
                document.body.classList.add('ready');
            } catch(e) {
                document.getElementById('content').innerHTML = '<pre style="color:red;">Error: ' + e.message + '\\n' + e.stack + '</pre>';
                document.body.classList.add('ready');
            }
        })();
        </script>
        </body>
        </html>
        """
    }

    private func escapeForJS(_ string: String) -> String {
        var result = string
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: "\"", with: "\\\"")
        result = result.replacingOccurrences(of: "\n", with: "\\n")
        result = result.replacingOccurrences(of: "\r", with: "\\r")
        result = result.replacingOccurrences(of: "\t", with: "\\t")
        result = result.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        result = result.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return result
    }
}
