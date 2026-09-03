#!/bin/bash
# YouTube Full Focus — build the distributable app and disk image.
#
# Usage:
#   ./build.sh              Build dist/YouTube Full Focus.app and dist/YouTube-Full-Focus-<version>.dmg
#   SKIP_DMG=1 ./build.sh   Build the .app only
#
# Requirements: the Xcode Command Line Tools (swiftc, codesign, hdiutil) — no
# full Xcode install and no third-party tooling.
#
# The result is ad-hoc signed, which is what lets it launch at all on Apple
# Silicon, but it is NOT notarised. macOS will quarantine it after download; the
# README and the download page explain how a user opens it the first time.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

APP_NAME="YouTube Full Focus"
BUNDLE_ID="com.focus.youtube.app"
MIN_MACOS="13.0"                      # Ventura, per the project's support floor
ARCHS=(arm64 x86_64)
VERSION="$(tr -d '[:space:]' < VERSION)"

BUILD_DIR="${SCRIPT_DIR}/build"
DIST_DIR="${SCRIPT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
DMG_PATH="${DIST_DIR}/YouTube-Full-Focus-${VERSION}.dmg"

# Shell files the app ships and runs as root — the actual product.
PAYLOAD_FILES=(
    config.env
    youtube-focus.css
    watchdog.sh
    com.focus.youtube.watchdog.plist
    install.sh
    uninstall.sh
)

info()    { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
die()     { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 1 — Preflight
# ---------------------------------------------------------------------------

command -v swiftc  >/dev/null || die "swiftc not found. Install the Xcode Command Line Tools: xcode-select --install"
command -v codesign >/dev/null || die "codesign not found. Install the Xcode Command Line Tools."

for f in "${PAYLOAD_FILES[@]}"; do
    [[ -f "${SCRIPT_DIR}/${f}" ]] || die "Missing payload file: ${f}"
done

SDK="$(xcrun --show-sdk-path)"
[[ -d "${SDK}" ]] || die "Could not locate the macOS SDK"

info "Building ${APP_NAME} ${VERSION} (min macOS ${MIN_MACOS})"

rm -rf "${BUILD_DIR}" "${APP_BUNDLE}"
mkdir -p "${BUILD_DIR}" "${DIST_DIR}"

# ---------------------------------------------------------------------------
# Step 2 — Compile one binary per architecture, then fuse them
# ---------------------------------------------------------------------------

SOURCES=("${SCRIPT_DIR}"/app/Sources/*.swift)

for arch in "${ARCHS[@]}"; do
    info "Compiling ${arch}…"
    swiftc \
        -O \
        -swift-version 5 \
        -parse-as-library \
        -sdk "${SDK}" \
        -target "${arch}-apple-macos${MIN_MACOS}" \
        -o "${BUILD_DIR}/YouTubeFocus-${arch}" \
        "${SOURCES[@]}"
done

lipo -create -output "${BUILD_DIR}/YouTubeFocus" \
    "${ARCHS[@]/#/${BUILD_DIR}/YouTubeFocus-}"
success "Universal binary: $(lipo -archs "${BUILD_DIR}/YouTubeFocus")"

# ---------------------------------------------------------------------------
# Step 3 — Render the icon from source
# ---------------------------------------------------------------------------

info "Rendering the app icon…"
swift "${SCRIPT_DIR}/app/make-icon.swift" "${BUILD_DIR}/AppIcon.icns" >/dev/null

# ---------------------------------------------------------------------------
# Step 4 — Assemble the bundle
# ---------------------------------------------------------------------------

CONTENTS="${APP_BUNDLE}/Contents"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources/payload"

cp "${BUILD_DIR}/YouTubeFocus" "${CONTENTS}/MacOS/YouTubeFocus"
chmod 755 "${CONTENTS}/MacOS/YouTubeFocus"
cp "${BUILD_DIR}/AppIcon.icns" "${CONTENTS}/Resources/AppIcon.icns"

for f in "${PAYLOAD_FILES[@]}"; do
    cp "${SCRIPT_DIR}/${f}" "${CONTENTS}/Resources/payload/${f}"
done
chmod 644 "${CONTENTS}/Resources/payload/"*
success "Payload embedded (${#PAYLOAD_FILES[@]} files)"

printf 'APPL????' > "${CONTENTS}/PkgInfo"

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>           <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>            <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>            <string>YouTubeFocus</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundleShortVersionString</key>    <string>${VERSION}</string>
    <key>CFBundleVersion</key>               <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>        <string>${MIN_MACOS}</string>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSHumanReadableCopyright</key>      <string>MIT License</string>
</dict>
</plist>
PLIST

plutil -lint "${CONTENTS}/Info.plist" >/dev/null || die "Generated Info.plist is invalid"

# ---------------------------------------------------------------------------
# Step 5 — Ad-hoc signature
# arm64 binaries must carry a signature to launch at all, so this is required
# even without a Developer ID. It does not satisfy Gatekeeper for downloads.
# ---------------------------------------------------------------------------

codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP_BUNDLE}"
codesign --verify --strict "${APP_BUNDLE}" || die "Signature verification failed"
success "Ad-hoc signed: ${APP_BUNDLE}"

# ---------------------------------------------------------------------------
# Step 6 — Disk image
# ---------------------------------------------------------------------------

if [[ "${SKIP_DMG:-0}" == "1" ]]; then
    info "SKIP_DMG=1 — stopping after the app bundle"
    exit 0
fi

STAGE="${BUILD_DIR}/dmg"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"
cp -R "${APP_BUNDLE}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"

rm -f "${DMG_PATH}"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGE}" \
    -ov -format UDZO \
    -quiet \
    "${DMG_PATH}"

success "Disk image: ${DMG_PATH} ($(du -h "${DMG_PATH}" | cut -f1))"

printf '\n'
printf '\033[1;32m========================================\033[0m\n'
printf '\033[1;32m  Build complete — %s %s\033[0m\n' "${APP_NAME}" "${VERSION}"
printf '\033[1;32m========================================\033[0m\n'
printf '\n'
printf '  App : %s\n' "${APP_BUNDLE}"
printf '  DMG : %s\n' "${DMG_PATH}"
printf '\n'
printf '  The build is ad-hoc signed, not notarised. After downloading, macOS\n'
printf '  blocks the first launch: System Settings > Privacy & Security >\n'
printf '  "Open Anyway".\n'
printf '\n'
