#!/bin/bash
set -euo pipefail

# Build a macOS .app bundle for ghBonk
# Usage: ./scripts/bundle.sh [--release|--debug]

CONFIG="${1:---release}"
if [[ "$CONFIG" == "--release" ]]; then
    BUILD_DIR=".build/release"
    swift build -c release
elif [[ "$CONFIG" == "--debug" ]]; then
    BUILD_DIR=".build/debug"
    swift build
else
    echo "Usage: $0 [--release|--debug]"
    exit 1
fi

APP_NAME="ghBonk"
BUNDLE_DIR=".build/${APP_NAME}.app"
BUNDLE_ID="dev.ghbonk.app"
VERSION="1.0.0"

echo "Creating app bundle at ${BUNDLE_DIR}..."

# Clean previous bundle
rm -rf "$BUNDLE_DIR"

# Create bundle structure
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

# Copy executable
cp "${BUILD_DIR}/${APP_NAME}" "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"

# Copy app icon
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"
fi

# Create Info.plist
cat > "${BUNDLE_DIR}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>ghBonk</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
    <key>NSUserNotificationAlertStyle</key>
    <string>banner</string>
</dict>
</plist>
PLIST

# Create PkgInfo
echo -n "APPL????" > "${BUNDLE_DIR}/Contents/PkgInfo"

# Code sign with development identity (stable signature for Keychain access).
# Falls back to ad-hoc if no identity is available.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | awk -F'"' '{print $2}')
if [[ -n "$IDENTITY" ]]; then
    codesign --force --deep --sign "$IDENTITY" "${BUNDLE_DIR}"
    echo "Signed with: $IDENTITY"
else
    codesign --force --deep --sign - "${BUNDLE_DIR}"
    echo "Signed ad-hoc (no development identity found)"
fi

echo "Done: ${BUNDLE_DIR}"
echo ""
echo "To run:  open ${BUNDLE_DIR}"
echo "To install: cp -R ${BUNDLE_DIR} /Applications/"
