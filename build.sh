#!/bin/bash
# Compila Game Hub y lo instala como "Game Hub.app".
# uso: ./build.sh [carpeta de instalación]   (por defecto ~/Applications)
set -euo pipefail; cd "$(dirname "$0")"
DEST="${1:-$HOME/Applications}"; APP="$DEST/Game Hub.app"; BUNDLE_ID="${GAMEHUB_BUNDLE_ID:-io.github.alejandroparis17.gamehub}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
swiftc -O -parse-as-library GameHub.swift -o "$T/GameHub"
swiftc -O tools/mkicon.swift -o "$T/mkicon"; "$T/mkicon" "$T/icon.png"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$T/GameHub" "$APP/Contents/MacOS/GameHub"
I="$T/AppIcon.iconset"; mkdir "$I"
for s in 16 32 64 128 256 512 1024; do sips -z $s $s "$T/icon.png" --out "$I/t$s.png" >/dev/null; done
cp "$I/t16.png" "$I/icon_16x16.png"; cp "$I/t32.png" "$I/icon_16x16@2x.png"; cp "$I/t32.png" "$I/icon_32x32.png"; cp "$I/t64.png" "$I/icon_32x32@2x.png"
cp "$I/t128.png" "$I/icon_128x128.png"; cp "$I/t256.png" "$I/icon_128x128@2x.png"; cp "$I/t256.png" "$I/icon_256x256.png"; cp "$I/t512.png" "$I/icon_256x256@2x.png"
cp "$I/t512.png" "$I/icon_512x512.png"; cp "$I/t1024.png" "$I/icon_512x512@2x.png"; rm "$I"/t*.png
iconutil -c icns "$I" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Game Hub</string><key>CFBundleDisplayName</key><string>Game Hub</string>
<key>CFBundleExecutable</key><string>GameHub</string><key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.games</string><key>GCSupportsControllerUserInteraction</key><true/>
</dict></plist>
P
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "instalado: $APP"
