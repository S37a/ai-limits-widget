#!/usr/bin/env bash
set -euo pipefail

APP="ai-limits-widget"
APPDIR="$APP.app"

rm -rf "$APPDIR"
swiftc main.swift -o "$APP" -framework Cocoa -framework SwiftUI -framework WebKit
mkdir -p "$APPDIR/Contents/MacOS"
cp "$APP" "$APPDIR/Contents/MacOS/$APP"
cat > "$APPDIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>AI Limits</string>
  <key>CFBundleDisplayName</key>
  <string>AI Limits Widget</string>
  <key>CFBundleIdentifier</key>
  <string>com.s37a.ai-limits-widget</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

echo "Built: $APPDIR"