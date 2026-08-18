#!/bin/bash
#
# Builds AutoConnect.app from the Swift package.
#
# SwiftPM produces a bare executable, but a menu-bar-only app needs a real bundle so that
# LSUIElement can suppress the Dock icon and so the code signature stays stable (which is what
# keeps the Keychain from re-prompting on every launch).
#
# Usage:
#   Scripts/make-app.sh                    # release build, signed with the first Apple Development identity
#   SIGN_IDENTITY="-" Scripts/make-app.sh  # ad-hoc signature
#   CONFIG=debug Scripts/make-app.sh       # debug build
#   VERSION=1.2.0 Scripts/make-app.sh      # stamp a version other than the default
#   REQUIRE_ICON=1 Scripts/make-app.sh     # fail instead of falling back to the generic icon
#
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP_NAME="AutoConnect"
BUNDLE_ID="com.pooya.AutoConnect"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP_DIR="build/${APP_NAME}.app"

echo "==> Building (${CONFIG})"
swift build -c "${CONFIG}" --product "${APP_NAME}"
BIN_PATH="$(swift build -c "${CONFIG}" --product "${APP_NAME}" --show-bin-path)"
BINARY="${BIN_PATH}/${APP_NAME}"

if [[ ! -x "${BINARY}" ]]; then
    echo "Build did not produce ${BINARY}" >&2
    exit 1
fi

echo "==> Assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BINARY}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# SwiftPM emits target resources as a side-by-side .bundle. Bundle.module looks in the main
# bundle's Resources directory first, so copying it here is what makes the menu bar icon resolve
# inside the packaged app (rather than only under `swift run`).
RESOURCE_BUNDLE="${BIN_PATH}/${APP_NAME}_${APP_NAME}.bundle"
if [[ -d "${RESOURCE_BUNDLE}" ]]; then
    cp -R "${RESOURCE_BUNDLE}" "${APP_DIR}/Contents/Resources/"
else
    echo "Missing ${RESOURCE_BUNDLE}; the menu bar icon will fall back to an SF Symbol" >&2
fi

# The app icon is an Icon Composer document. actool turns it into both an Assets.car, which is
# what macOS 26 reads to draw the layered Liquid Glass icon, and a plain AppIcon.icns for
# everything older. Missing keys just mean the generic app icon, so a failure here is not fatal.
#
# Both paths passed to actool are absolute on purpose: it resolves relative paths against its own
# working directory, not the shell's, and fails claiming the output directory does not exist.
ICON_SOURCE="${PWD}/Icons/AppIcon.icon"
ICON_KEYS=""
if [[ -d "${ICON_SOURCE}" ]] && xcrun -f actool >/dev/null 2>&1; then
    echo "==> Compiling app icon"
    xcrun actool "${ICON_SOURCE}" \
        --compile "${PWD}/${APP_DIR}/Contents/Resources" \
        --app-icon AppIcon \
        --output-partial-info-plist "$(mktemp -t autoconnect-icon-plist)" \
        --platform macosx \
        --minimum-deployment-target 14.0 \
        --errors --warnings > /dev/null
    ICON_KEYS=$'    <key>CFBundleIconFile</key>\n    <string>AppIcon</string>\n    <key>CFBundleIconName</key>\n    <string>AppIcon</string>'
elif [[ "${REQUIRE_ICON:-0}" == "1" ]]; then
    echo "REQUIRE_ICON is set but ${ICON_SOURCE} or actool is missing" >&2
    exit 1
else
    echo "No ${ICON_SOURCE} or no actool; the app will use the generic icon" >&2
fi

# actool reports some failures on stdout and still exits 0, so check that it really produced the
# compiled catalog rather than trusting the exit status.
if [[ -n "${ICON_KEYS}" && ! -f "${APP_DIR}/Contents/Resources/Assets.car" ]]; then
    echo "actool ran but produced no Assets.car" >&2
    exit 1
fi

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
${ICON_KEYS}
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- Menu bar only: no Dock icon, no main window. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Local build. Secrets stay in this Mac's Keychain.</string>
    <!--
      App Transport Security has to be relaxed, and this is not a shortcut.

      ATS demands ECDHE for forward secrecy and refuses plain DHE. This gateway negotiates
      DHE-RSA-AES256-SHA256, so ATS rejects the handshake before any delegate is consulted: the
      app reports "A TLS error caused the secure connection to fail" while curl connects fine.
      Corporate VPN concentrators are routinely this conservative, and their certificates are
      usually privately signed as well, which ATS also refuses.

      A per-domain exception cannot be written here, because nothing about any gateway is
      compiled in: the user types an address and the app asks it for the rest.

      What replaces ATS is stronger for this purpose, not weaker. Every gateway request pins the
      certificate by SHA1 in GatewayClient, so an unexpected certificate is refused outright
      rather than merely warned about. The identity provider, which is a normal public host,
      still goes through full system trust evaluation in SAMLLoginController.
    -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
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
