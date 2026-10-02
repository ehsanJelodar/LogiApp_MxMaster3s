#!/bin/bash
# Builds MxMaster3s.app from MxMaster3s.swift.
# Put this script next to MxMaster3s.swift, then run:
#     bash build.sh
#
# Requires Xcode Command Line Tools (one-time, free):
#     xcode-select --install

set -euo pipefail

APP_NAME="MxMaster3s"
SRC=(main.swift battery_helper.swift)

if [ ! -f "$SRC" ]; then
    echo "Error: $SRC not found in the current folder."
    exit 1
fi
if ! command -v swiftc >/dev/null 2>&1; then
    echo "Error: swiftc not found. Run:  xcode-select --install"
    exit 1
fi

echo "Compiling $SRC ..."
swiftc -parse-as-library -O -o "$APP_NAME" "${SRC[@]}" -framework IOKit -framework CoreFoundation

echo "Bundling $APP_NAME.app ..."
rm -rf "$APP_NAME.app"
ROOT="$APP_NAME.app/Contents"
mkdir -p "$ROOT/MacOS" "$ROOT/Resources"
mv "$APP_NAME" "$ROOT/MacOS/$APP_NAME"

# Generate ICNS from mouse.png
if [ -f "mouse.png" ]; then
    ICONSET="MxMaster3s.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    sips -z 16 16     "mouse.png" --out "$ICONSET/icon_16x16.png"
    sips -z 32 32     "mouse.png" --out "$ICONSET/icon_16x16@2x.png"
    sips -z 32 32     "mouse.png" --out "$ICONSET/icon_32x32.png"
    sips -z 64 64     "mouse.png" --out "$ICONSET/icon_32x32@2x.png"
    sips -z 128 128   "mouse.png" --out "$ICONSET/icon_128x128.png"
    sips -z 256 256   "mouse.png" --out "$ICONSET/icon_128x128@2x.png"
    sips -z 256 256   "mouse.png" --out "$ICONSET/icon_256x256.png"
    sips -z 512 512   "mouse.png" --out "$ICONSET/icon_256x256@2x.png"
    sips -z 512 512   "mouse.png" --out "$ICONSET/icon_512x512.png"
    sips -z 1024 1024 "mouse.png" --out "$ICONSET/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET" -o "$ROOT/Resources/MxMaster3s.icns"
    rm -rf "$ICONSET"
    echo "  → App icon bundled from mouse.png"
else
    echo "  ⚠  mouse.png not found — no app icon"
fi

cat > "$ROOT/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MxMaster3s</string>
    <key>CFBundleIdentifier</key>
    <string>local.MxMaster3s</string>
    <key>CFBundleName</key>
    <string>MxMaster3s</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleIconFile</key>
    <string>MxMaster3s</string>
    <key>CFBundleIcons</key>
    <dict>
        <key>CFBundlePrimaryIcon</key>
        <dict>
            <key>CFBundleIconFiles</key>
            <array>
                <string>MxMaster3s</string>
            </array>
        </dict>
    </dict>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

# Ad-hoc signature so macOS treats the app as a stable identity
# (needed for the Accessibility permission to stick to the .app itself).
codesign --force -s - "$ROOT/MacOS/$APP_NAME"
codesign --force -s - "$APP_NAME.app"

echo
echo "Done: $(pwd)/$APP_NAME.app"
echo "Next steps:"
echo "  1. Double-click $APP_NAME.app (or:  open $APP_NAME.app)"
echo "  2. Grant Accessibility when prompted:"
echo "     System Preferences > Security & Privacy > Privacy > Accessibility"
echo "  3. Optional autostart: System Preferences > Users & Groups >"
echo "     Login Items, add $APP_NAME.app"