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
VERSION="${VERSION:-1.2.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP_DIR="build/${APP_NAME}.app"

# Always universal, and not only so an Intel Mac can run it.
#
# Passing more than one --arch is what moves SwiftPM off its native build system and onto XCBuild,
# and the two generate *different* `Bundle.module` accessors:
#
#   native   looks in <App>.app/ and then in an absolute .build path baked in at compile time
#   XCBuild  looks in <App>.app/Contents/Resources/ first, which is where this script puts it
#
# A native build therefore produces an app that resolves its resources only through the build
# directory of the machine that compiled it. It runs there and traps at launch everywhere else,
# which is exactly how 1.0.0 shipped a bundle that could not open for anyone. Do not "optimise"
# this back to a single arch.
#
# The rpath is for Sparkle. Its install name is @rpath/Sparkle.framework/Versions/B/Sparkle, and
# SwiftPM links a binary framework but has no notion of embedding one in a bundle, so the search
# path that finds it inside Contents/Frameworks has to be asked for here. Without it the app links
# cleanly and then dies at launch with "Library not loaded".
BUILD_FLAGS=(
    -c "${CONFIG}" --product "${APP_NAME}" --arch arm64 --arch x86_64
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks
)

echo "==> Building (${CONFIG}, universal)"
swift build "${BUILD_FLAGS[@]}"
BIN_PATH="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
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
COPIED_BUNDLE="${APP_DIR}/Contents/Resources/${APP_NAME}_${APP_NAME}.bundle"
if [[ -d "${RESOURCE_BUNDLE}" ]]; then
    cp -R "${RESOURCE_BUNDLE}" "${APP_DIR}/Contents/Resources/"
else
    echo "Missing ${RESOURCE_BUNDLE}; the menu bar icon will fall back to an SF Symbol" >&2
    exit 1
fi

# XCBuild emits a real bundle, with Contents/Info.plist, which is what `Bundle.init(url:)` needs
# to return anything at all. Check it rather than assume it: "the directory is present" is the
# check that passed while 1.0.0 was fatally broken.
if [[ ! -f "${COPIED_BUNDLE}/Contents/Info.plist" ]]; then
    echo "${COPIED_BUNDLE} has no Contents/Info.plist, so Bundle.module will trap at launch" >&2
    exit 1
fi

# Sparkle, embedded by hand for the same reason: SwiftPM links a binary framework but never copies
# one into a bundle. The universal slice of the xcframework is the one to take, since the app is
# universal and a framework with a single architecture would strand the other.
#
# Preferred source is the build products directory, because that is the copy the binary was linked
# against. The artifacts directory is the fallback for a build that did not stage it there.
FRAMEWORKS_DIR="${APP_DIR}/Contents/Frameworks"
SPARKLE_SOURCE=""
if [[ -d "${BIN_PATH}/Sparkle.framework" ]]; then
    SPARKLE_SOURCE="${BIN_PATH}/Sparkle.framework"
else
    for slice in .build/artifacts/*/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework; do
        if [[ -d "${slice}" ]]; then
            SPARKLE_SOURCE="${slice}"
            break
        fi
    done
fi

if [[ -z "${SPARKLE_SOURCE}" ]]; then
    echo "No Sparkle.framework to embed; run 'swift package resolve' and build again" >&2
    exit 1
fi

echo "==> Embedding Sparkle from ${SPARKLE_SOURCE}"
mkdir -p "${FRAMEWORKS_DIR}"
# ditto, not cp -R: the framework is a versioned bundle held together by symlinks, and copying it
# any other way either flattens those or ships the payload twice.
rm -rf "${FRAMEWORKS_DIR}/Sparkle.framework"
ditto "${SPARKLE_SOURCE}" "${FRAMEWORKS_DIR}/Sparkle.framework"

SPARKLE_FRAMEWORK="${FRAMEWORKS_DIR}/Sparkle.framework"
SPARKLE_VERSION_DIR="${SPARKLE_FRAMEWORK}/Versions/B"

# An arm64-only Sparkle inside a universal app fails to launch on Intel and nowhere else, which is
# the hardest kind of break to notice from this machine.
SPARKLE_ARCHS="$(lipo -archs "${SPARKLE_VERSION_DIR}/Sparkle")"
for arch in arm64 x86_64; do
    if [[ " ${SPARKLE_ARCHS} " != *" ${arch} "* ]]; then
        echo "Embedded Sparkle is missing ${arch} (has: ${SPARKLE_ARCHS})" >&2
        exit 1
    fi
done

# The rpath asked for at link time, verified rather than assumed: a build that quietly dropped it
# produces an app that cannot start at all, and this is the cheapest place to catch that.
#
# The output is captured before it is searched, not piped into `grep -q`. That pipeline fails even
# when the rpath is present: grep exits at the first match, otool dies of SIGPIPE, and `pipefail`
# reports the whole pipeline as failed. It looks exactly like a missing rpath.
LOAD_COMMANDS="$(otool -l "${APP_DIR}/Contents/MacOS/${APP_NAME}")"
if [[ "${LOAD_COMMANDS}" != *"@executable_path/../Frameworks"* ]]; then
    echo "The binary has no @executable_path/../Frameworks rpath, so Sparkle cannot load" >&2
    exit 1
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
    <!--
      Sparkle. The feed is the appcast.xml committed at the root of the repo and served raw by
      GitHub; each entry in it points at the zip attached to that tag's release.

      SUPublicEDKey is the public half of the EdDSA key that signs those zips. The private half
      lives in one Mac's login Keychain and nowhere else, and Sparkle refuses any update this key
      does not verify. That is what makes an unnotarised download over raw.githubusercontent.com
      safe to install: the transport is not trusted, the signature is.

      Replacing this key strands every copy already installed, in the same way that changing the
      bundle id strands the Keychain items. Automatic checks are daily, and are refused outright
      while a tunnel is up; see UpdateController.
    -->
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/sirpooya/AutoConnect/main/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>XPeIzL4GHFXBMLCP+A/vxqQE4Bn8tGi7jkw9sRBHXSc=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
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

# The notary service rejects a signature with no secure timestamp, so a Developer ID build asks
# Apple's timestamp server for one. Every other identity signs offline, which keeps a local build
# working without the network and is all an Apple Development or ad-hoc signature can do anyway.
if [[ "${SIGN_IDENTITY}" == "Developer ID Application"* ]]; then
    TIMESTAMP_FLAG="--timestamp"
else
    TIMESTAMP_FLAG="--timestamp=none"
fi

# The hardened runtime turns on Library Validation, which requires every library loaded into the
# process to carry the same Team ID as the main binary. An ad-hoc signature has no Team ID at all,
# so an ad-hoc build with the hardened runtime cannot load Sparkle: the process dies in dyld,
# before any code of ours runs, with
#
#   Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
#   ... mapping process and mapped file (non-platform) have different Team IDs
#
# A real identity signs the app and Sparkle alike, so validation passes and the flag stays, which
# is what a notarised build would need. It is dropped only for ad-hoc, where it buys nothing:
# notarisation is not possible without a Developer ID anyway. This is the same failure that shipped
# twice in the sibling app before it was understood; do not "restore" the flag for consistency.
if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    RUNTIME_FLAGS=()
    echo "==> Ad-hoc signature: no hardened runtime, or Sparkle cannot be loaded"
else
    RUNTIME_FLAGS=(--options runtime)
fi

sign_item() {
    codesign --force "${RUNTIME_FLAGS[@]+"${RUNTIME_FLAGS[@]}"}" "${TIMESTAMP_FLAG}" \
        --sign "${SIGN_IDENTITY}" "$1" 2>&1 | sed 's/^/    /'
}

echo "==> Signing with: ${SIGN_IDENTITY}"
# Inside out, and the order is not a preference: signing the app seals whatever is nested in it, so
# anything signed afterwards invalidates the outer signature. Sparkle brings four nested programs
# of its own, and Updater.app is the one that must survive the check, since it is the process that
# replaces this app while this app is not running.
for xpc in "${SPARKLE_VERSION_DIR}/XPCServices/Downloader.xpc" \
    "${SPARKLE_VERSION_DIR}/XPCServices/Installer.xpc"; do
    [[ -d "${xpc}" ]] || continue
    sign_item "${xpc}"
done
# if-blocks rather than `[[ … ]] && sign`, which under `set -e` exits the script when the test is
# simply false.
if [[ -f "${SPARKLE_VERSION_DIR}/Autoupdate" ]]; then
    sign_item "${SPARKLE_VERSION_DIR}/Autoupdate"
fi
if [[ -d "${SPARKLE_VERSION_DIR}/Updater.app" ]]; then
    sign_item "${SPARKLE_VERSION_DIR}/Updater.app"
fi
sign_item "${SPARKLE_FRAMEWORK}"
sign_item "${APP_DIR}"

echo "==> Verifying"
codesign --verify --deep --strict "${APP_DIR}" && echo "    signature OK"

echo "    architectures: $(lipo -archs "${APP_DIR}/Contents/MacOS/${APP_NAME}")"

echo
echo "Built ${APP_DIR}"
echo
echo "Run it:        open ${APP_DIR}"
echo "Install it:    cp -R ${APP_DIR} /Applications/"
echo "Stop it:       osascript -e 'quit app \"${APP_NAME}\"'"
