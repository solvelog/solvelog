#!/bin/bash
# Builds SolveLog.app from source.
#
#   scripts/build-app.sh                 # → build/SolveLog.app
#   scripts/build-app.sh --install       # also copy it to /Applications
#   INSTALL_NAME="SolveLog Dev" scripts/build-app.sh --install   # install under another name
#
# Requires the Xcode Command Line Tools (xcode-select --install). The app is ad-hoc signed;
# on first launch macOS may ask you to confirm opening it (right-click → Open).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
APP="build/SolveLog.app"

echo "→ Compiling (release)…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/SolveLog"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SolveLog"
cp Resources/web/index.html "$APP/Contents/Resources/index.html"

echo "→ Rendering icon…"
mkdir -p build/icon
swiftc -swift-version 5 scripts/make_icon.swift -o build/icon/make_icon
build/icon/make_icon build/icon/icon.png
ICONSET="build/icon/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SolveLog</string>
  <key>CFBundleDisplayName</key><string>SolveLog</string>
  <key>CFBundleIdentifier</key><string>io.github.solvelog</string>
  <key>CFBundleExecutable</key><string>SolveLog</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 SolveLog contributors. GPL-3.0-or-later.</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP"
echo "✓ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  NAME="${INSTALL_NAME:-SolveLog}"
  DEST="/Applications/$NAME.app"
  osascript -e "quit app \"$NAME\"" 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "✓ Installed $DEST"
fi
