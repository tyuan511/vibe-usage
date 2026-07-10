#!/usr/bin/env bash
# Renders docs/usage-share-preview.png from the SwiftUI preview renderer.
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
".build/${CONFIG}/VibeUsagePreviewRenderer" "${OUTPUT}" --share-card
echo "==> Wrote ${OUTPUT}"
