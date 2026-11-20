#!/bin/bash
# Builds Jobbar.app (native menu bar app) into ./build. Usage: ./build.sh [--install]
#   --install  also copies it to ~/Applications/Jobbar.app
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --package-path MenuBarApp
BIN="$(swift build -c release --package-path MenuBarApp --show-bin-path)/Jobbar"
APP=build/Jobbar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Jobbar"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.zeronerodahero.jobbar</string>
  <key>CFBundleName</key><string>Jobbar</string>
  <key>CFBundleDisplayName</key><string>Jobbar</string>
  <key>CFBundleExecutable</key><string>Jobbar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Built $APP"
if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications && rm -rf ~/Applications/Jobbar.app && cp -R "$APP" ~/Applications/
  echo "Installed ~/Applications/Jobbar.app"
fi
