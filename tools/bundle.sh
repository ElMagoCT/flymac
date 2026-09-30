#!/bin/sh
# Build FlyMac.app with SwiftPM only (no Xcode). Usage: tools/bundle.sh [debug|release]
set -e
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product FlyMac 2>&1 | grep -E 'error|warning: unre|Compiling|Build' | tail -3
BIN=".build/$CONFIG"
APP="build/FlyMac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/FlyMac" "$APP/Contents/MacOS/FlyMac"
# SwiftPM resource bundles are looked up in Contents/Resources by Bundle.module.
for b in "$BIN"/*.bundle; do [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
VERSION=$(grep -o 'static let version = "[^"]*"' Sources/FlyMac/AppModel.swift | cut -d'"' -f2)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>FlyMac</string>
  <key>CFBundleDisplayName</key><string>FlyMac</string>
  <key>CFBundleIdentifier</key><string>com.sixpencelabs.flymac</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>FlyMac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>FlyMac shows video from UVC capture cards you choose as a live source.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>macOS only reveals the current Wi-Fi name to apps with Location access. FlyMac uses it to notice an aircraft's Quick Transfer hotspot. Location itself is never stored or sent.</string>
  <key>NSLocalNetworkUsageDescription</key><string>FlyMac talks to the aircraft over its own Wi-Fi hotspot to list and download media.</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
</dict></plist>
PLIST
[ -f tools/AppIcon.icns ] && cp tools/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ad-hoc sign so TCC prompts (camera, location) attach to a stable identity.
codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "built $APP ($CONFIG)"
