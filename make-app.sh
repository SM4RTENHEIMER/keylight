#!/bin/sh
# Build keylight and wrap it as ~/Applications/keylight.app so it can live in the Dock.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
sh build.sh
APP="$HOME/Applications/keylight.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp keylight "$APP/Contents/MacOS/keylight"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>keylight</string>
  <key>CFBundleDisplayName</key><string>keylight</string>
  <key>CFBundleIdentifier</key><string>app.keylight.serato</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>keylight</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>keylight</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Icon: rendered by make-icon.swift, packed by iconutil.
rm -rf /tmp/keylight.iconset && mkdir -p /tmp/keylight.iconset
xcrun swiftc -swift-version 5 -O -framework AppKit -o /tmp/make-icon make-icon.swift
/tmp/make-icon /tmp/keylight.iconset
iconutil -c icns /tmp/keylight.iconset -o "$APP/Contents/Resources/keylight.icns"
touch "$APP"
echo "built $APP"
