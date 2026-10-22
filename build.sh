#!/bin/zsh
# Builds Elconvo.app (Apple Silicon + Intel) with the Command Line Tools; no Xcode needed.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=1.0.2
APP=build/Elconvo.app
rm -rf "$APP" build/Elconvo.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
    swiftc -parse-as-library -swift-version 5 -O -target $arch-apple-macos14 Sources/*.swift -o build/Elconvo-$arch
done
lipo -create build/Elconvo-arm64 build/Elconvo-x86_64 -output "$APP/Contents/MacOS/Elconvo"
rm build/Elconvo-arm64 build/Elconvo-x86_64

swift Icon.swift build/Elconvo.iconset
iconutil -c icns build/Elconvo.iconset -o "$APP/Contents/Resources/Elconvo.icns"
rm -rf build/Elconvo.iconset

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Elconvo</string>
    <key>CFBundleDisplayName</key><string>Elconvo</string>
    <key>CFBundleIdentifier</key><string>com.itzkin.elconvo</string>
    <key>CFBundleExecutable</key><string>Elconvo</string>
    <key>CFBundleIconFile</key><string>Elconvo</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Elad Itzkin</string>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>Elconvo: Size &amp; Info</string></dict>
            <key>NSMessage</key><string>showSizeInfo</string>
            <key>NSRequiredContext</key><dict/>
            <key>NSSendFileTypes</key><array><string>public.item</string></array>
        </dict>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>Elconvo: Show Metadata</string></dict>
            <key>NSMessage</key><string>showMetadata</string>
            <key>NSRequiredContext</key><dict/>
            <key>NSSendFileTypes</key><array><string>public.item</string></array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Any file</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.item</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
