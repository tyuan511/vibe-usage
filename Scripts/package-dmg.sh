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
VERSION="${VERSION:-0.1.0}"
DMG_STAGING_DIR=".build/dmg/${APP_NAME}"
DMG_PATH=".build/${APP_NAME}-${VERSION}.dmg"

echo "==> Building ${APP_NAME}.app"
Scripts/build-app.sh "${CONFIG}"

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
