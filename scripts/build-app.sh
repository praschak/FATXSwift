#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
    echo "Build FATX Browser on macOS with Apple's Command Line Tools installed." >&2
    exit 1
fi
if [ "$(id -u)" -eq 0 ]; then
    echo "Run this script as your normal Mac user, not root. Type exit to leave the root shell first." >&2
    exit 1
fi
swift build -c release -j 1 --product FATXSecurityProbe
swift build -c release -j 1 --product FATXBrowser
swift build -c release -j 1 --product fatxbridge
swift build -c release -j 1 --product fatx
# SwiftPM build products have different locations with native and Swift Build.
FATX_BIN_DIR="$(swift build -c release --show-bin-path)"
for FATX_PRODUCT in FATXBrowser fatxbridge fatx FATXSecurityProbe; do
    if [ ! -x "$FATX_BIN_DIR/$FATX_PRODUCT" ]; then
        echo "Missing build product: $FATX_BIN_DIR/$FATX_PRODUCT" >&2
        exit 1
    fi
done
APP="$PWD/dist/FATX Browser.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$FATX_BIN_DIR/FATXBrowser" "$APP/Contents/MacOS/FATXBrowser"
cp "$FATX_BIN_DIR/fatxbridge" "$APP/Contents/MacOS/fatxbridge"
cp "$FATX_BIN_DIR/fatx" "$APP/Contents/MacOS/fatx"
cp "$FATX_BIN_DIR/FATXSecurityProbe" "$APP/Contents/MacOS/FATXSecurityProbe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>FATXBrowser</string>
<key>CFBundleIdentifier</key><string>com.fatxswift.browser</string>
<key>CFBundleName</key><string>FATX Browser</string>
<key>CFBundleDisplayName</key><string>FATX Browser</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>100</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>FATXSwift contributors. MIT license.</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$APP/Contents/MacOS/FATXSecurityProbe"
/usr/bin/codesign --force --sign - "$APP/Contents/MacOS/fatxbridge"
/usr/bin/codesign --force --sign - "$APP/Contents/MacOS/fatx"
/usr/bin/codesign --force --sign - "$APP"
echo "Built: $APP"
if [ "${1:-}" = --open ]; then /usr/bin/open "$APP"; fi
