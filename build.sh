#!/bin/sh
# Builds "GH Actions Bar.app" next to this script. Pass --install to copy it to ~/Applications.
# Override the bundle id with BUNDLE_ID=com.yourname.ghactionsbar ./build.sh
set -e
cd "$(dirname "$0")"
APP="GH Actions Bar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# Universal binary: Apple Silicon + Intel.
TMP=$(mktemp -d)
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos13" main.swift -o "$TMP/$ARCH"
done
lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$APP/Contents/MacOS/GHActionsBar"
rm -rf "$TMP"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>GH Actions Bar</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID:-app.ghactionsbar}</string>
  <key>CFBundleExecutable</key><string>GHActionsBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION:-0.1.0}</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
if [ "$1" = "--install" ]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/"$APP"
  cp -R "$APP" ~/Applications/
  echo "Installed to ~/Applications/$APP"
else
  echo "Built $(pwd)/$APP"
fi
