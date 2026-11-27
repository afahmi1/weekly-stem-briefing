#!/usr/bin/env bash
# Build WeeklyStemBriefing.app with swiftc only (Command Line Tools, no Xcode).
# Checkout-relative: every path is resolved from this script's own location, never $HOME.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/Sources"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="WeeklyStemBriefing"
BUNDLE_ID="local.abduel.weeklystembriefing"
APP="$BUILD_DIR/$APP_NAME.app"
BIN="$APP/Contents/MacOS/$APP_NAME"
SOURCES=("$SRC_DIR/main.swift" "$SRC_DIR/WidgetResize.swift" "$SRC_DIR/WidgetAppearance.swift"
         "$SRC_DIR/WidgetSnapshots.swift" "$SRC_DIR/Thermocline.swift")
for source in "${SOURCES[@]}"; do
  [[ -f "$source" ]] || { printf 'Missing source: %s\n' "$source" >&2; exit 1; }
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "compiling (${#SOURCES[@]} sources):"
printf '  %s\n' "${SOURCES[@]}"
swiftc -O -target arm64-apple-macosx14.0 \
  -framework AppKit -framework SwiftUI -framework Combine \
  -o "$BIN" "${SOURCES[@]}"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "ad-hoc signing skipped"
echo "built $APP"
