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
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
DMG_STAGING_DIR=".build/dmg/${APP_NAME}"

# Every artifact that ships is signed with the same identity, so sign the app
# (which build-app.sh does), then the image built around it.
VERSION="${VERSION}" BUILD_NUMBER="${BUILD_NUMBER}" SIGN_IDENTITY="${SIGN_IDENTITY}" \
    Scripts/build-app.sh "${CONFIG}"

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

# Notarize (and staple) the app before the image is built around it: a
# notarization ticket cannot be stapled onto a zip, and stapling the app now
# means the copy inside the DMG is already self-sufficient. With no credentials
# in the environment this is a no-op and the DMG is signed but not notarized.
Scripts/notarize-artifact.sh "${DMG_STAGING_DIR}/${APP_NAME}.app" "${SIGN_IDENTITY}"

echo "==> Creating ${DMG_PATH}"
hdiutil create \
    -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "${DMG_STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}" >/dev/null

# Sign, notarize and staple the image itself. Gatekeeper assesses a downloaded
# DMG on its own signature, so an unsigned image is rejected with
# "source=no usable signature" even when the app inside it is notarized.
Scripts/notarize-artifact.sh "${DMG_PATH}" "${SIGN_IDENTITY}"

echo "==> Built ${DMG_PATH}"
