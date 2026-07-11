#!/usr/bin/env bash
# Builds VibeUsage.app and packages it into a compressed DMG.
#
# Usage:
#   VERSION=0.1.0 BUILD_NUMBER=1 Scripts/package-dmg.sh release
set -euo pipefail

CONFIG="${1:-release}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="VibeUsage"
VERSION="${VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DMG_STAGING_DIR=".build/dmg/${APP_NAME}"

echo "==> Building ${APP_NAME}.app"
VERSION="${VERSION}" BUILD_NUMBER="${BUILD_NUMBER}" Scripts/build-app.sh "${CONFIG}"

# Keep the DMG name and volume version aligned with the app bundle. When no
# explicit VERSION was supplied, build-app.sh resolves the latest Git tag.
if [ -z "${VERSION}" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' ".build/${APP_NAME}.app/Contents/Info.plist")"
fi
DMG_PATH=".build/${APP_NAME}-${VERSION}.dmg"

echo "==> Staging DMG"
rm -rf "${DMG_STAGING_DIR}"
rm -f "${DMG_PATH}"
mkdir -p "${DMG_STAGING_DIR}"

cp -R ".build/${APP_NAME}.app" "${DMG_STAGING_DIR}/"
ln -s /Applications "${DMG_STAGING_DIR}/Applications"

echo "==> Creating ${DMG_PATH}"
hdiutil create \
    -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "${DMG_STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}" >/dev/null

echo "==> Built ${DMG_PATH}"
