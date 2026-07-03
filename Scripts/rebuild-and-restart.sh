#!/usr/bin/env bash
# Rebuilds VibeUsage.app and relaunches it, stopping any running instance first.
#
# Usage: Scripts/rebuild-and-restart.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_BUNDLE=".build/VibeUsage.app"
EXECUTABLE_NAME="VibeUsageApp"

if pgrep -x "${EXECUTABLE_NAME}" >/dev/null 2>&1; then
    echo "==> Stopping running ${EXECUTABLE_NAME}"
    pkill -x "${EXECUTABLE_NAME}" || true
    for _ in {1..20}; do
        if ! pgrep -x "${EXECUTABLE_NAME}" >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done
fi

"${ROOT_DIR}/Scripts/build-app.sh" "${CONFIG}"

echo "==> Launching ${APP_BUNDLE}"
open "${APP_BUNDLE}"
