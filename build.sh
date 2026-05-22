#!/bin/bash

set -euo pipefail

APP_NAME="QuickMD"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
BUILD_DIR="$SCRIPT_DIR/.build"
CACHE_DIR="$BUILD_DIR/cache"
DIST_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/dist}"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
VENDOR_DIR="$RESOURCES_DIR/vendor"
HIGHLIGHT_DIR="$VENDOR_DIR/highlight"
LICENSES_DIR="$RESOURCES_DIR/licenses"
ICON_SOURCE="$SCRIPT_DIR/assets/icon.svg"
ICON_NAME="AppIcon"
ICON_PATH="$RESOURCES_DIR/$ICON_NAME.icns"

# Dependency versions
MARKED_VERSION="15.0.7"
DOMPURIFY_VERSION="3.3.2"
MERMAID_VERSION="11.4.1"
KATEX_VERSION="0.16.21"
HIGHLIGHTJS_VERSION="11.11.1"

usage() {
    cat <<'EOF'
QuickMD Build Script
====================

Usage:
  ./build.sh           Build the app bundle into dist/
  ./build.sh build     Same as default
  ./build.sh clean     Remove dist/ and build outputs
  ./build.sh help      Show this help message

Requirements:
  - macOS 12.0+ with Command Line Tools installed
  - Internet connection (for first build to download dependencies)

After building:
  1. Move dist/QuickMD.app to /Applications/
  2. Double-click any .md file to open with QuickMD
  3. Or right-click -> Open With -> QuickMD
EOF
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Error: Missing required command: %s\n' "$1" >&2
        printf 'Please install Xcode Command Line Tools: xcode-select --install\n' >&2
        exit 1
    fi
}

extract_npm_file() {
    local package_name="$1"
    local version="$2"
    local archive_member="$3"
    local destination="$4"
    local archive_path="$CACHE_DIR/${package_name//\//-}-${version}.tgz"
    local archive_url="https://registry.npmjs.org/${package_name}/-/${package_name##*/}-${version}.tgz"

    mkdir -p "$CACHE_DIR"

    if [ ! -f "$archive_path" ]; then
        printf '  Downloading %s@%s...\n' "$package_name" "$version"
        curl -fsSL "$archive_url" -o "$archive_path"
    fi

    local temp_dir
    temp_dir="$(mktemp -d)"
    tar -xzf "$archive_path" -C "$temp_dir" "$archive_member" 2>/dev/null || true

    if [ -f "$temp_dir/$archive_member" ]; then
        mkdir -p "$(dirname "$destination")"
        cp "$temp_dir/$archive_member" "$destination"
    fi
    rm -rf "$temp_dir"
}

extract_npm_dir() {
    local package_name="$1"
    local version="$2"
    local archive_member="$3"
    local destination="$4"
    local archive_path="$CACHE_DIR/${package_name//\//-}-${version}.tgz"
    local archive_url="https://registry.npmjs.org/${package_name}/-/${package_name##*/}-${version}.tgz"

    mkdir -p "$CACHE_DIR"

    if [ ! -f "$archive_path" ]; then
        printf '  Downloading %s@%s...\n' "$package_name" "$version"
        curl -fsSL "$archive_url" -o "$archive_path"
    fi

    local temp_dir
    temp_dir="$(mktemp -d)"
    tar -xzf "$archive_path" -C "$temp_dir" "$archive_member" 2>/dev/null || true
    rm -rf "$destination"
    if [ -d "$temp_dir/$archive_member" ]; then
        cp -R "$temp_dir/$archive_member" "$destination"
    fi
    rm -rf "$temp_dir"
}

SDK_PATH=""

prepare_environment() {
    printf '  Checking build environment...\n'
    require_command bash
    require_command clang
    require_command curl
    require_command iconutil
    require_command plutil
    require_command sips
    require_command xcrun
    require_command tar

    SDK_PATH="$(xcrun --show-sdk-path)"
    mkdir -p "$DIST_DIR"
    printf '  Build environment ready (SDK: %s)\n' "$SDK_PATH"
}

build_native_binary() {
    printf '  Compiling native binary...\n'
    clang \
        -fobjc-arc \
        -Wall \
        -Wextra \
        -Wno-unused-parameter \
        -O2 \
        -isysroot "$SDK_PATH" \
        -framework Cocoa \
        -framework CoreServices \
        -framework UniformTypeIdentifiers \
        -framework WebKit \
        "$SRC_DIR/main.m" \
        -o "$MACOS_DIR/QuickMD"
    printf '  Binary compiled successfully\n'
}

generate_default_icon() {
    local temp_dir iconset_dir
    temp_dir="$(mktemp -d)"
    iconset_dir="$temp_dir/$ICON_NAME.iconset"
    mkdir -p "$iconset_dir"

    local helper_src helper_bin
    helper_src="$(mktemp "${TMPDIR:-/tmp}/icongen-XXXXXX.m")"
    helper_bin="${helper_src%.m}"

    cat > "$helper_src" <<'OBJC'
#import <AppKit/AppKit.h>
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 1;
        NSString *output = [NSString stringWithUTF8String:argv[1]];
        NSInteger sz = atoi(argv[2]);

        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:sz pixelsHigh:sz
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        rep.size = NSMakeSize(sz, sz);

        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        [NSGraphicsContext setCurrentContext:ctx];

        // Rounded rect background - Tokyo Night inspired
        NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(sz*0.02, sz*0.02, sz*0.96, sz*0.96)
                                                          xRadius:sz * 0.22 yRadius:sz * 0.22];
        NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithRed:0.10 green:0.11 blue:0.15 alpha:1.0]
                                                            endingColor:[NSColor colorWithRed:0.15 green:0.16 blue:0.24 alpha:1.0]];
        [gradient drawInBezierPath:bg angle:135];

        // Draw "MD" text
        NSFont *font = [NSFont systemFontOfSize:sz * 0.30 weight:NSFontWeightBold];
        NSDictionary *attrs = @{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: [NSColor colorWithRed:0.48 green:0.64 blue:0.97 alpha:1.0],
        };
        NSString *text = @"MD";
        NSSize textSize = [text sizeWithAttributes:attrs];
        NSPoint point = NSMakePoint((sz - textSize.width) / 2.0, (sz - textSize.height) / 2.0 + sz * 0.02);
        [text drawAtPoint:point withAttributes:attrs];

        // Draw subtle accent line below
        NSBezierPath *line = [NSBezierPath bezierPath];
        CGFloat lineY = sz * 0.25;
        [line moveToPoint:NSMakePoint(sz * 0.28, lineY)];
        [line lineToPoint:NSMakePoint(sz * 0.72, lineY)];
        [line setLineWidth:sz * 0.025];
        [[NSColor colorWithRed:0.48 green:0.64 blue:0.97 alpha:0.5] setStroke];
        [line stroke];

        [NSGraphicsContext restoreGraphicsState];

        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (![png writeToFile:output atomically:YES]) return 1;
    }
    return 0;
}
OBJC

    clang -fobjc-arc -isysroot "$SDK_PATH" -framework AppKit \
        "$helper_src" -o "$helper_bin" 2>/dev/null

    local sizes=(16 32 64 128 256 512 1024)
    for s in "${sizes[@]}"; do
        "$helper_bin" "$temp_dir/icon_${s}.png" "$s" 2>/dev/null || true
    done

    if [ -f "$temp_dir/icon_16.png" ]; then
        cp "$temp_dir/icon_16.png" "$iconset_dir/icon_16x16.png"
        cp "$temp_dir/icon_32.png" "$iconset_dir/icon_16x16@2x.png"
        cp "$temp_dir/icon_32.png" "$iconset_dir/icon_32x32.png"
        cp "$temp_dir/icon_64.png" "$iconset_dir/icon_32x32@2x.png"
        cp "$temp_dir/icon_128.png" "$iconset_dir/icon_128x128.png"
        cp "$temp_dir/icon_256.png" "$iconset_dir/icon_128x128@2x.png"
        cp "$temp_dir/icon_256.png" "$iconset_dir/icon_256x256.png"
        cp "$temp_dir/icon_512.png" "$iconset_dir/icon_256x256@2x.png"
        cp "$temp_dir/icon_512.png" "$iconset_dir/icon_512x512.png"
        cp "$temp_dir/icon_1024.png" "$iconset_dir/icon_512x512@2x.png"
        iconutil -c icns "$iconset_dir" -o "$ICON_PATH" 2>/dev/null || true
    fi

    rm -f "$helper_src" "$helper_bin"
    rm -rf "$temp_dir"
}

build_app_icon() {
    printf '  Building app icon...\n'

    if [ -f "$ICON_SOURCE" ]; then
        local temp_dir iconset_dir source_png
        temp_dir="$(mktemp -d)"
        iconset_dir="$temp_dir/$ICON_NAME.iconset"
        source_png="$temp_dir/icon_1024.png"

        # Rasterize SVG
        local helper_src helper_bin
        helper_src="$(mktemp "${TMPDIR:-/tmp}/svg2png-XXXXXX.m")"
        helper_bin="${helper_src%.m}"

        cat > "$helper_src" <<'OBJC'
#import <AppKit/AppKit.h>
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) return 1;
        NSString *input = [NSString stringWithUTF8String:argv[1]];
        NSString *output = [NSString stringWithUTF8String:argv[2]];
        NSInteger sz = atoi(argv[3]);
        NSImage *img = [[NSImage alloc] initWithContentsOfFile:input];
        if (!img) return 1;
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:sz pixelsHigh:sz
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        rep.size = NSMakeSize(sz, sz);
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
        [img drawInRect:NSMakeRect(0, 0, sz, sz)];
        [NSGraphicsContext restoreGraphicsState];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (![png writeToFile:output atomically:YES]) return 1;
    }
    return 0;
}
OBJC

        clang -fobjc-arc -isysroot "$SDK_PATH" -framework AppKit \
            "$helper_src" -o "$helper_bin" 2>/dev/null && \
        "$helper_bin" "$ICON_SOURCE" "$source_png" 1024 2>/dev/null

        if [ -f "$source_png" ]; then
            mkdir -p "$iconset_dir"
            sips -z 16 16 "$source_png" --out "$iconset_dir/icon_16x16.png" >/dev/null
            sips -z 32 32 "$source_png" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
            sips -z 32 32 "$source_png" --out "$iconset_dir/icon_32x32.png" >/dev/null
            sips -z 64 64 "$source_png" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
            sips -z 128 128 "$source_png" --out "$iconset_dir/icon_128x128.png" >/dev/null
            sips -z 256 256 "$source_png" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
            sips -z 256 256 "$source_png" --out "$iconset_dir/icon_256x256.png" >/dev/null
            sips -z 512 512 "$source_png" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
            sips -z 512 512 "$source_png" --out "$iconset_dir/icon_512x512.png" >/dev/null
            cp "$source_png" "$iconset_dir/icon_512x512@2x.png"
            iconutil -c icns "$iconset_dir" -o "$ICON_PATH"
            rm -f "$helper_src" "$helper_bin"
            rm -rf "$temp_dir"
            printf '  App icon built from SVG\n'
            return
        fi

        rm -f "$helper_src" "$helper_bin"
        rm -rf "$temp_dir"
    fi

    # Fallback: generate programmatic icon
    generate_default_icon
    printf '  App icon generated\n'
}

download_vendor_deps() {
    printf '  Downloading vendor dependencies...\n'

    # marked.js
    extract_npm_file "marked" "$MARKED_VERSION" "package/lib/marked.umd.js" "$VENDOR_DIR/marked.umd.js"
    extract_npm_file "marked" "$MARKED_VERSION" "package/LICENSE.md" "$LICENSES_DIR/marked-LICENSE.md"

    # DOMPurify
    extract_npm_file "dompurify" "$DOMPURIFY_VERSION" "package/dist/purify.min.js" "$VENDOR_DIR/purify.min.js"
    extract_npm_file "dompurify" "$DOMPURIFY_VERSION" "package/LICENSE" "$LICENSES_DIR/dompurify-LICENSE"

    # Mermaid
    extract_npm_file "mermaid" "$MERMAID_VERSION" "package/dist/mermaid.min.js" "$VENDOR_DIR/mermaid.min.js"
    extract_npm_file "mermaid" "$MERMAID_VERSION" "package/LICENSE" "$LICENSES_DIR/mermaid-LICENSE"

    # KaTeX
    extract_npm_file "katex" "$KATEX_VERSION" "package/dist/katex.min.css" "$VENDOR_DIR/katex.min.css"
    extract_npm_file "katex" "$KATEX_VERSION" "package/dist/katex.min.js" "$VENDOR_DIR/katex.min.js"
    extract_npm_file "katex" "$KATEX_VERSION" "package/dist/contrib/auto-render.min.js" "$VENDOR_DIR/katex-auto-render.min.js"
    extract_npm_dir "katex" "$KATEX_VERSION" "package/dist/fonts" "$VENDOR_DIR/fonts"
    extract_npm_file "katex" "$KATEX_VERSION" "package/LICENSE" "$LICENSES_DIR/katex-LICENSE"

    # highlight.js
    mkdir -p "$HIGHLIGHT_DIR"
    extract_npm_file "@highlightjs/cdn-assets" "$HIGHLIGHTJS_VERSION" "package/highlight.min.js" "$HIGHLIGHT_DIR/highlight.min.js"
    extract_npm_file "@highlightjs/cdn-assets" "$HIGHLIGHTJS_VERSION" "package/styles/github.min.css" "$HIGHLIGHT_DIR/github.min.css"
    extract_npm_file "@highlightjs/cdn-assets" "$HIGHLIGHTJS_VERSION" "package/styles/github-dark.min.css" "$HIGHLIGHT_DIR/github-dark.min.css"

    printf '  Vendor dependencies ready\n'
}

build_bundle() {
    printf '\n'
    printf '========================================\n'
    printf '     Building QuickMD v1.0.0\n'
    printf '========================================\n'
    printf '\n'

    prepare_environment

    rm -rf "$APP_DIR"
    mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$VENDOR_DIR" "$HIGHLIGHT_DIR" "$LICENSES_DIR"

    build_native_binary
    build_app_icon

    # Copy source resources
    cp "$SRC_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
    cp "$SRC_DIR/QuickMDRenderer.sh" "$RESOURCES_DIR/QuickMDRenderer.sh"
    cp "$SRC_DIR/viewer.css" "$RESOURCES_DIR/viewer.css"
    cp "$SRC_DIR/viewer.js" "$RESOURCES_DIR/viewer.js"
    chmod 755 "$RESOURCES_DIR/QuickMDRenderer.sh"

    download_vendor_deps

    # Validate
    plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
    bash -n "$RESOURCES_DIR/QuickMDRenderer.sh"

    # Ad-hoc code sign
    if command -v codesign >/dev/null 2>&1; then
        printf '  Signing app bundle...\n'
        codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || \
            printf '  Warning: ad-hoc codesign failed; app may need manual approval.\n'
    fi

    printf '\n'
    printf '========================================\n'
    printf '  BUILD SUCCESSFUL!\n'
    printf '========================================\n'
    printf '\n'
    printf '  App: %s\n' "$APP_DIR"
    printf '\n'
    printf '  Next steps:\n'
    printf '    1. cp -r "%s" /Applications/\n' "$APP_DIR"
    printf '    2. open /Applications/QuickMD.app\n'
    printf '    3. Right-click .md -> Get Info -> Open With -> QuickMD -> Change All\n'
    printf '\n'
}

clean_outputs() {
    rm -rf "$DIST_DIR" "$BUILD_DIR"
    printf 'Cleaned build outputs\n'
}

main() {
    local command="${1:-build}"

    case "$command" in
        build)
            build_bundle
            ;;
        clean)
            clean_outputs
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
}

main "$@"
