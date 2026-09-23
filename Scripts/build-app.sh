#!/usr/bin/env bash
# Builds the VibeUsageApp executable via SwiftPM and assembles it into a
# double-clickable VibeUsage.app bundle.
#
# Signed ad-hoc by default (local use). Pass a real Developer ID identity to
# produce a bundle that can be notarized and shipped:
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/build-app.sh release
#
# Usage: Scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="VibeUsage"
EXECUTABLE_NAME="VibeUsageApp"
BUILD_DIR=".build/${CONFIG}"
APP_BUNDLE=".build/${APP_NAME}.app"
VERSION="${VERSION:-}"
if [ -z "${VERSION}" ]; then
    LATEST_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
    VERSION="${LATEST_TAG#v}"
fi
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"
# SwiftPM's output directory is toolchain-dependent (for example
# .build/out/Products/Debug on newer SwiftPM). Never assume .build/debug:
# copying from that stale legacy path can silently package old resources,
# including an old model_prices.json.
BUILD_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"

echo "==> Using build products from ${BUILD_DIR}"
echo "==> Assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${APP_BUNDLE}/Contents/Frameworks"

cp "${BUILD_DIR}/${EXECUTABLE_NAME}" "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"

# SwiftPM's standalone executable rpath points at Contents/MacOS. Add the
# standard application-bundle framework location before signing the bundle.
if ! otool -l "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}" | grep -Fq "@loader_path/../Frameworks"; then
    install_name_tool -add_rpath "@loader_path/../Frameworks" "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"
fi

cp "Scripts/package-Info.plist.template" "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${APP_BUNDLE}/Contents/Info.plist"
printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"

# Copy every SwiftPM-generated resource bundle (one per target that declares
# `resources:`, e.g. VibeUsage_VibeUsagePricing.bundle) into the standard app
# resources directory.
shopt -s nullglob
for bundle in "${BUILD_DIR}"/*.bundle; do
    case "$(basename "$bundle")" in
        *Tests.bundle) continue ;;
    esac
    echo "    + $(basename "$bundle")"
    cp -R "$bundle" "${APP_BUNDLE}/Contents/Resources/"
done
shopt -u nullglob

# SwiftPM links Sparkle dynamically but does not assemble application bundles.
# Copy the complete framework (including Updater.app and its XPC services) and
# preserve its symlinks and executable permissions.
SPARKLE_FRAMEWORK_PATH="$(find .build/artifacts/sparkle -path '*/macos-*/Sparkle.framework' -type d -print -quit 2>/dev/null || true)"
if [ -z "${SPARKLE_FRAMEWORK_PATH}" ]; then
    echo "error: Sparkle.framework was not found in SwiftPM artifacts" >&2
    exit 1
fi
echo "    + Sparkle.framework"
ditto "${SPARKLE_FRAMEWORK_PATH}" "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"

# Compile the app icon asset catalog if one has been populated (see Resources/AppIcon.appiconset).
if [ -f "Resources/AppIcon.appiconset/Contents.json" ] && command -v actool >/dev/null 2>&1; then
    echo "==> Compiling AppIcon asset catalog"
    ASSET_CATALOG_DIR="$(mktemp -d)/Assets.xcassets"
    mkdir -p "$ASSET_CATALOG_DIR"
    cp -R "Resources/AppIcon.appiconset" "$ASSET_CATALOG_DIR/"
    actool "$ASSET_CATALOG_DIR" \
        --compile "${APP_BUNDLE}/Contents/Resources" \
        --platform macosx \
        --minimum-deployment-target 26.0 \
        --app-icon AppIcon \
        --output-partial-info-plist /dev/null \
        >/dev/null
fi

if [ "${SIGN_IDENTITY}" = "-" ]; then
    echo "==> codesign (ad-hoc)"
    codesign --force --deep --sign - "${APP_BUNDLE}"
    codesign --verify --deep --strict "${APP_BUNDLE}"
else
    # Fail with the list of usable identities rather than codesign's bare
    # "no identity found", which does not say which keychain was searched.
    if ! security find-identity -v -p codesigning | grep -Fq "${SIGN_IDENTITY}"; then
        echo "error: signing identity '${SIGN_IDENTITY}' is not in the keychain" >&2
        echo "       identities available for code signing:" >&2
        security find-identity -v -p codesigning >&2 || true
        exit 1
    fi

    echo "==> codesign (${SIGN_IDENTITY})"
    # Sign inside-out: every nested Sparkle item first, the app bundle last.
    # `--deep` is deprecated for *signing* and silently drops the hardened
    # runtime from nested code, which fails notarization and can leave Sparkle's
    # Updater.app unable to relaunch the app. Each nested item therefore gets
    # the runtime flag and a secure timestamp explicitly.
    SPARKLE_B="${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework/Versions/B"
    for nested in \
        "${SPARKLE_B}/XPCServices/Downloader.xpc" \
        "${SPARKLE_B}/XPCServices/Installer.xpc" \
        "${SPARKLE_B}/Updater.app" \
        "${SPARKLE_B}/Autoupdate" \
        "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"; do
        [ -e "${nested}" ] || continue
        echo "    + ${nested#${APP_BUNDLE}/Contents/Frameworks/}"
        codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${nested}"
    done
    codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"
    codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
fi

echo "==> Built ${APP_BUNDLE}"
echo "    Run with: open ${APP_BUNDLE}"
