#!/usr/bin/env bash
# Builds the VibeUsageApp executable via SwiftPM and assembles it into a
# double-clickable VibeUsage.app bundle. Ad-hoc signed for local use.
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
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

echo "==> Assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${EXECUTABLE_NAME}" "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"

cp "Scripts/package-Info.plist.template" "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${APP_BUNDLE}/Contents/Info.plist"
printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"

# Copy every SwiftPM-generated resource bundle (one per target that declares
# `resources:`, e.g. VibeUsage_VibeUsagePricing.bundle, plus test fixture
# bundles which are harmless to skip) next to the executable so
# Bundle.module lookups inside each library resolve correctly at runtime.
shopt -s nullglob
for bundle in "${BUILD_DIR}"/*.bundle; do
    case "$(basename "$bundle")" in
        *Tests.bundle) continue ;;
    esac
    echo "    + $(basename "$bundle")"
    cp -R "$bundle" "${APP_BUNDLE}/Contents/Resources/"
done
shopt -u nullglob

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
else
    echo "==> codesign (${SIGN_IDENTITY})"
fi
codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"

echo "==> Built ${APP_BUNDLE}"
echo "    Run with: open ${APP_BUNDLE}"
