# QuickMD

A lightweight, native macOS Markdown previewer. Double-click any `.md` file and get a beautifully rendered preview instantly.

![QuickMD preview window](screenshot.png)

**macOS 12+ · Objective-C / AppKit / WKWebView · JavaScript rendering · MIT**

## Explore the implementation

- [Native application](src/main.m): document opening, window lifecycle, file watching and PDF export.
- [Renderer](src/QuickMDRenderer.sh) and [viewer logic](src/viewer.js): Markdown-to-HTML rendering and interactions.
- [Swift Quick Look extension](QuickMDPreview/PreviewViewController.swift): a separate preview integration.
- [Rendering regression checks](test/): task-checkbox mapping and KaTeX trust settings.

[Build and install](#build) · [Keyboard shortcuts](#keyboard-shortcuts) · [Architecture](#architecture)

## Features

- **GFM Support** — Full GitHub Flavored Markdown (tables, task lists, strikethrough, autolinks)
- **Syntax Highlighting** — 190+ languages via highlight.js with light/dark themes
- **Mermaid Diagrams** — Flowcharts, sequence diagrams, Gantt charts, and more
- **LaTeX Math** — Inline and display math via KaTeX (`$...$` and `$$...$$`)
- **Dark Mode** — Auto-adapts to system appearance, with manual toggle (Cmd+Shift+D)
- **Live Reload** — Automatically refreshes when the source file changes
- **PDF Export** — Export rendered Markdown to PDF (Cmd+Shift+E)
- **Table of Contents** — Sidebar TOC navigation (Cmd+Shift+T)
- **Find in Document** — Full-text search with highlighting (Cmd+F)
- **Local Images** — Relative image paths resolved correctly
- **Code Copy** — One-click copy button on code blocks
- **Zero Dependencies** — No Electron, no Node.js runtime needed

## Requirements

- macOS 12.0 (Monterey) or later
- Xcode Command Line Tools (`xcode-select --install`)
- Internet connection (first build only, to download JS libraries)

## Build

```bash
cd QuickMD
chmod +x build.sh
./build.sh
```

The app will be built to `dist/QuickMD.app`.

## Install

```bash
cp -r dist/QuickMD.app /Applications/
```

## Set as Default Markdown Viewer

1. Right-click any `.md` file in Finder
2. Select "Get Info"
3. Under "Open With", select "QuickMD"
4. Click "Change All..."

## Usage

- **Open file**: Double-click a `.md` file, or use File → Open (Cmd+O)
- **Reload**: Cmd+R (also auto-reloads on file change)
- **Toggle dark mode**: Cmd+Shift+D
- **Toggle TOC sidebar**: Cmd+Shift+T
- **Find text**: Cmd+F
- **Export PDF**: Cmd+Shift+E
- **Print**: Cmd+P
- **Reveal source**: File → Reveal Source File

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+O | Open file |
| Cmd+R | Reload preview |
| Cmd+Shift+D | Toggle dark/light mode |
| Cmd+Shift+T | Toggle TOC sidebar |
| Cmd+F | Find in document |
| Cmd+G | Find next |
| Cmd+Shift+G | Find previous |
| Cmd+Shift+E | Export as PDF |
| Cmd+P | Print |
| Cmd+W | Close window |
| Cmd+Q | Quit |

## Architecture

```
QuickMD.app/
├── Contents/
│   ├── Info.plist
│   ├── MacOS/
│   │   └── QuickMD          (native Obj-C binary)
│   └── Resources/
│       ├── QuickMDRenderer.sh (HTML generator)
│       ├── viewer.css         (styles)
│       ├── viewer.js          (rendering logic)
│       └── vendor/            (JS libraries)
│           ├── marked.umd.js
│           ├── purify.min.js
│           ├── mermaid.min.js
│           ├── katex.min.js
│           ├── katex.min.css
│           ├── katex-auto-render.min.js
│           ├── fonts/
│           └── highlight/
│               ├── highlight.min.js
│               ├── github.min.css
│               └── github-dark.min.css
```

## How It Works

1. Native Objective-C app opens `.md` files
2. Shell script reads the Markdown, base64-encodes it into an HTML template
3. WKWebView loads the HTML with bundled JS libraries
4. marked.js parses Markdown → HTML
5. DOMPurify sanitizes the output
6. highlight.js adds syntax highlighting
7. Mermaid renders diagrams
8. KaTeX renders math formulas
9. FSEvents watches for file changes and auto-reloads

## License

MIT
