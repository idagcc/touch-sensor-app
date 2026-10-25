#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
swift build -c release --arch arm64 --arch x86_64
APP_DIR="$PROJECT_DIR/dist/Touch Player.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
cp "$BIN_DIR/TouchPlayer" "$APP_DIR/Contents/MacOS/TouchPlayer"
swift scripts/create-assets.swift "$PROJECT_DIR"
iconutil -c icns .build/artwork/AppIcon.iconset -o "$APP_DIR/Contents/Resources/AppIcon.icns"
if [ ! -d "$PROJECT_DIR/dist/Touch Player Data" ]; then
    cp -R "Touch Player Data" "$PROJECT_DIR/dist/Touch Player Data"
fi
if [ -d "$APP_DIR/Contents/Resources/DefaultData" ]; then
    rm -rf "$APP_DIR/Contents/Resources/DefaultData"
fi
cp -R "Touch Player Data" "$APP_DIR/Contents/Resources/DefaultData"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Touch Player</string>
<key>CFBundleDisplayName</key><string>Touch Player</string>
<key>CFBundleIdentifier</key><string>com.touchplayer.desktop</string>
<key>CFBundleExecutable</key><string>TouchPlayer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3.0</string>
<key>CFBundleVersion</key><string>5</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSDesktopFolderUsageDescription</key><string>Load your video files and config.json from the Touch Player Data folder beside the app.</string>
<key>NSDocumentsFolderUsageDescription</key><string>Load the video files and settings you choose for this installation.</string>
<key>NSDownloadsFolderUsageDescription</key><string>Load your installation videos and settings if you keep Touch Player in Downloads.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP_DIR"
cp README.md "$PROJECT_DIR/dist/READ ME.md"
PACKAGE_DIR="$PROJECT_DIR/.build/package/Touch Player"
if [ -d "$PROJECT_DIR/.build/package" ]; then
    rm -rf "$PROJECT_DIR/.build/package"
fi
mkdir -p "$PACKAGE_DIR"
ditto "$APP_DIR" "$PACKAGE_DIR/Touch Player.app"
ditto "$PROJECT_DIR/dist/Touch Player Data" "$PACKAGE_DIR/Touch Player Data"
cp README.md "$PACKAGE_DIR/READ ME.md"
cp -R Arduino "$PACKAGE_DIR/Arduino"
ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_DIR" "$PROJECT_DIR/dist/TouchPlayer-macOS.zip"
printf 'Built: %s\n' "$APP_DIR"
