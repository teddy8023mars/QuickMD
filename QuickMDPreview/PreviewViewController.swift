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
        self.view = webView
    }

    // MARK: - QLPreviewingController (callback-based, macOS 10.15+)

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            let markdown = try String(contentsOf: url, encoding: .utf8)
            let baseURL = url.deletingLastPathComponent()
            let html = buildPreviewHTML(markdown: markdown, filename: url.lastPathComponent, baseURL: baseURL)
            webView.loadHTMLString(html, baseURL: baseURL)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                handler(nil)
            }
        } catch {
            handler(error)
        }
    }

    // MARK: - HTML Generation

    private func buildPreviewHTML(markdown: String, filename: String, baseURL: URL) -> String {
        let escapedMarkdown = escapeForJS(markdown)

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <base href="\(baseURL.absoluteString)">
        <title>\(filename)</title>
        <link rel="stylesheet" href="https://unpkg.com/katex@0.16.21/dist/katex.min.css">
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
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
            font-size: 15px;
            line-height: 1.7;
            color: var(--fg);
            background: var(--bg);
            margin: 0;
            padding: 24px 40px;
            max-width: 900px;
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
        pre code { background: none; padding: 0; font-size: 0.85em; }
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
        input[type="checkbox"] { margin-right: 0.5em; vertical-align: middle; }
        .task-list-item { list-style: none; margin-left: -1.5em; }
        </style>
        </head>
        <body>
        <div id="content"></div>
        <script src="https://unpkg.com/marked@15.0.7/marked.min.js"></script>
        <script src="https://unpkg.com/dompurify@3.3.2/dist/purify.min.js"></script>
        <script src="https://unpkg.com/@highlightjs/cdn-assets@11.11.1/highlight.min.js"></script>
        <script src="https://unpkg.com/katex@0.16.21/dist/katex.min.js"></script>
        <script src="https://unpkg.com/katex@0.16.21/dist/contrib/auto-render.min.js"></script>
        <script>
        (function() {
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
            // Disable checkboxes in preview
            const checkboxes = contentEl.querySelectorAll('input[type="checkbox"]');
            for (const cb of checkboxes) cb.disabled = true;
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
