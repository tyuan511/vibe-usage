#!/usr/bin/env bash
# Renders the menu bar share preview from the real SwiftUI popover view.
#
# Usage: Scripts/regenerate-preview.sh [output-path]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT="${1:-docs/usage-share-preview.png}"
CONFIG="${PREVIEW_CONFIG:-release}"

echo "==> swift build -c ${CONFIG} --product VibeUsagePreviewRenderer"
swift build -c "${CONFIG}" --product VibeUsagePreviewRenderer

echo "==> Rendering ${OUTPUT}"
".build/${CONFIG}/VibeUsagePreviewRenderer" "${OUTPUT}" --menu-bar
echo "==> Wrote ${OUTPUT}"
