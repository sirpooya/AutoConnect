#!/bin/bash
#
# Builds MacAuth.app from the Swift package.
#
# SwiftPM produces a bare executable, but a menu-bar-only app needs a real bundle so that
# LSUIElement can suppress the Dock icon and so the code signature stays stable (which is what
# keeps the Keychain from re-prompting on every launch).
#
# Usage:
#   Scripts/make-app.sh                    # release build, signed with the first Apple Development identity
#   SIGN_IDENTITY="-" Scripts/make-app.sh  # ad-hoc signature
#   CONFIG=debug Scripts/make-app.sh       # debug build
#
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP_NAME="MacAuth"
BUNDLE_ID="com.pooya.MacAuth"
VERSION="0.1.0"
BUILD_NUMBER="1"
APP_DIR="build/${APP_NAME}.app"

echo "==> Building (${CONFIG})"
swift build -c "${CONFIG}" --product "${APP_NAME}"
BINARY="$(swift build -c "${CONFIG}" --product "${APP_NAME}" --show-bin-path)/${APP_NAME}"

if [[ ! -x "${BINARY}" ]]; then
    echo "Build did not produce ${BINARY}" >&2
    exit 1
fi

echo "==> Assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BINARY}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- Menu bar only: no Dock icon, no main window. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Local build. Secrets stay in this Mac's Keychain.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

# A stable signing identity matters: re-signing with a different one makes macOS re-prompt for
# Keychain access. Prefer a real Apple Development certificate, fall back to ad-hoc.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development/ {print $2; exit}')"
    SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi

echo "==> Signing with: ${SIGN_IDENTITY}"
codesign --force --options runtime --timestamp=none \
    --sign "${SIGN_IDENTITY}" "${APP_DIR}" 2>&1 | sed 's/^/    /'

echo "==> Verifying"
codesign --verify --deep --strict "${APP_DIR}" && echo "    signature OK"

echo
echo "Built ${APP_DIR}"
echo
echo "Run it:        open ${APP_DIR}"
echo "Install it:    cp -R ${APP_DIR} /Applications/"
echo "Stop it:       osascript -e 'quit app \"${APP_NAME}\"'"
