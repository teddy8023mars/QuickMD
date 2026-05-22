#!/bin/bash
# build-ql.sh — Build QuickMD with Quick Look Extension
# Requires Xcode (for swiftc with proper framework linking)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="QuickMD"
BUNDLE_ID="com.quickmd.app"
EXT_NAME="QuickMDPreview"
EXT_BUNDLE_ID="com.quickmd.app.QuickMDPreview"
DIST_DIR="$SCRIPT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
EXT_BUNDLE="$APP_BUNDLE/Contents/PlugIns/$EXT_NAME.appex"
MIN_MACOS="13.0"

# ─── Clean ───────────────────────────────────────────────────────────
if [[ "$1" == "clean" ]]; then
    rm -rf "$DIST_DIR"
    echo "Cleaned build outputs"
    exit 0
fi

echo "═══════════════════════════════════════════════════════"
echo "  Building $APP_NAME with Quick Look Extension"
echo "═══════════════════════════════════════════════════════"

# ─── Step 1: Build main app (same as before) ─────────────────────────
echo ""
echo "▶ Step 1: Building main app..."

rm -rf "$DIST_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Compile main.m
clang -fobjc-arc -framework Cocoa -framework WebKit -framework Quartz -framework UniformTypeIdentifiers \
    -mmacosx-version-min=$MIN_MACOS \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    src/main.m

# Copy resources
cp src/Info.plist "$APP_BUNDLE/Contents/"
cp src/viewer.css "$APP_BUNDLE/Contents/Resources/"
cp src/viewer.js "$APP_BUNDLE/Contents/Resources/"
cp src/QuickMDRenderer.sh "$APP_BUNDLE/Contents/Resources/"
chmod +x "$APP_BUNDLE/Contents/Resources/QuickMDRenderer.sh"

# Write PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "  ✓ Main app built"

# ─── Step 2: Build Quick Look Extension ──────────────────────────────
echo ""
echo "▶ Step 2: Building Quick Look Extension..."

mkdir -p "$EXT_BUNDLE/Contents/MacOS"
mkdir -p "$EXT_BUNDLE/Contents/Resources"

# Compile Swift extension
swiftc \
    -target "$(uname -m)-apple-macosx$MIN_MACOS" \
    -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    -framework Cocoa \
    -framework WebKit \
    -framework Quartz \
    -module-name "$EXT_NAME" \
    -emit-executable \
    -o "$EXT_BUNDLE/Contents/MacOS/$EXT_NAME" \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    -Xlinker -rpath -Xlinker "@executable_path/../../../../Frameworks" \
    QuickMDPreview/PreviewViewController.swift

# Copy extension Info.plist
cp QuickMDPreview/Info.plist "$EXT_BUNDLE/Contents/"

# Copy resources needed by extension
cp src/viewer.css "$EXT_BUNDLE/Contents/Resources/"

# Write PkgInfo for extension
echo -n "XPC!????" > "$EXT_BUNDLE/Contents/PkgInfo"

echo "  ✓ Quick Look Extension built"

# ─── Step 3: Download JS libraries for extension ─────────────────────
echo ""
echo "▶ Step 3: Downloading JS libraries for extension..."

RESOURCES="$EXT_BUNDLE/Contents/Resources"

# marked.js
if [ ! -f "$RESOURCES/marked.min.js" ]; then
    curl -sL "https://cdn.jsdelivr.net/npm/marked@12/marked.min.js" -o "$RESOURCES/marked.min.js"
fi

# highlight.js
if [ ! -f "$RESOURCES/highlight.min.js" ]; then
    curl -sL "https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/highlight.min.js" -o "$RESOURCES/highlight.min.js"
fi

# DOMPurify
if [ ! -f "$RESOURCES/purify.min.js" ]; then
    curl -sL "https://cdn.jsdelivr.net/npm/dompurify@3/dist/purify.min.js" -o "$RESOURCES/purify.min.js"
fi

# Mermaid
if [ ! -f "$RESOURCES/mermaid.min.js" ]; then
    curl -sL "https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js" -o "$RESOURCES/mermaid.min.js"
fi

# KaTeX
if [ ! -f "$RESOURCES/katex.min.js" ]; then
    curl -sL "https://cdn.jsdelivr.net/npm/katex@0.16/dist/katex.min.js" -o "$RESOURCES/katex.min.js"
fi
if [ ! -f "$RESOURCES/katex.min.css" ]; then
    curl -sL "https://cdn.jsdelivr.net/npm/katex@0.16/dist/katex.min.css" -o "$RESOURCES/katex.min.css"
fi
if [ ! -f "$RESOURCES/auto-render.min.js" ]; then
    curl -sL "https://cdn.jsdelivr.net/npm/katex@0.16/dist/contrib/auto-render.min.js" -o "$RESOURCES/auto-render.min.js"
fi

echo "  ✓ JS libraries ready"

# ─── Step 4: Code sign ───────────────────────────────────────────────
echo ""
echo "▶ Step 4: Code signing..."

codesign --force --sign - --deep "$EXT_BUNDLE"
codesign --force --sign - --deep "$APP_BUNDLE"

echo "  ✓ Code signed"

# ─── Done ────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✅ Build complete: $APP_BUNDLE"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "  Install:"
echo "    cp -r \"$APP_BUNDLE\" /Applications/"
echo ""
echo "  After install:"
echo "    1. Open QuickMD.app once"
echo "    2. Go to System Settings → Privacy & Security → Extensions → Quick Look"
echo "    3. Enable 'QuickMD Preview'"
echo "    4. Select a .md file in Finder and press Space!"
echo ""
