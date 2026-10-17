#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# --no-install only assembles build/Pulse.app, for scripts/release.sh.
INSTALL=1
[[ "${1:-}" == "--no-install" ]] && INSTALL=0
BUNDLE_ID=io.github.florianriquelme.pulse
VERSION=${VERSION:-0.0.0-dev}

# No x86_64 slice: the SMC, HID temperature and powerlog readings are Apple Silicon specific.
swift build -c release --product Pulse
APP=build/Pulse.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Pulse" "$APP/Contents/MacOS/Pulse"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>Pulse</string>
    <key>CFBundleDisplayName</key><string>Pulse</string>
    <key>CFBundleExecutable</key><string>Pulse</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [[ ! -f build/AppIcon.icns ]]; then
    ICONSET=build/AppIcon.iconset
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    swift scripts/make-icon.swift build/icon-1024.png
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

[[ $INSTALL == 1 ]] || exit 0

pkill -x Pulse || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Pulse.app"
ditto "$APP" "$HOME/Applications/Pulse.app"
echo "Installed ~/Applications/Pulse.app"
