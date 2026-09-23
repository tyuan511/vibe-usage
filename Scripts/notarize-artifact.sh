#!/usr/bin/env bash
# Notarize and staple an already code-signed artifact (.app or .dmg), then
# verify Gatekeeper accepts it. Notarization is what lets a Developer ID build
# run on a machine that never saw the build.
#
# Usage:
#   Scripts/notarize-artifact.sh <path-to-.app-or-.dmg> [signing-identity]
#
# A .dmg is signed here first (with the identity, when given): the app build
# signs the .app, but the disk image built around it is a new artifact with no
# signature of its own, and Gatekeeper assesses a downloaded image separately.
#
# Credentials come from the environment; with none set the step is skipped so a
# local build still works:
#   App Store Connect API key: APPLE_API_KEY (path to .p8),
#                              APPLE_API_KEY_ID, APPLE_API_ISSUER
#   Apple ID:                  APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
set -euo pipefail

ARTIFACT="${1:-}"
IDENTITY="${2:-}"
if [ -z "${ARTIFACT}" ]; then
    echo "usage: Scripts/notarize-artifact.sh <path-to-.app-or-.dmg> [signing-identity]" >&2
    exit 1
fi
if [ ! -e "${ARTIFACT}" ]; then
    echo "error: ${ARTIFACT} does not exist" >&2
    exit 1
fi

# Sign the DMG even when notarization credentials are not configured. Signing
# and notarization are separate steps; a local Developer ID build should still
# produce a signed disk image.
if [ ! -d "${ARTIFACT}" ] && [ -n "${IDENTITY}" ] && [ "${IDENTITY}" != "-" ]; then
    echo "==> codesign dmg (${IDENTITY})"
    codesign --force --timestamp --sign "${IDENTITY}" "${ARTIFACT}"
fi

# notarytool takes its credentials as flags, so the CI secrets never have to be
# imported into a keychain. It rejects a bare .app, so an app is zipped first.
NOTARY_ARGS=()
if [ -n "${APPLE_API_KEY:-}" ] && [ -n "${APPLE_API_KEY_ID:-}" ] && [ -n "${APPLE_API_ISSUER:-}" ]; then
    NOTARY_ARGS=(--key "${APPLE_API_KEY}" --key-id "${APPLE_API_KEY_ID}" --issuer "${APPLE_API_ISSUER}")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
    NOTARY_ARGS=(--apple-id "${APPLE_ID}" --team-id "${APPLE_TEAM_ID}" --password "${APPLE_APP_PASSWORD}")
else
    echo "==> Skipping notarization of $(basename "${ARTIFACT}") (no credentials in the environment)"
    exit 0
fi

SUBMISSION="${ARTIFACT}"
SCRATCH=""
if [ -d "${ARTIFACT}" ]; then
    SCRATCH="$(mktemp -d)"
    SUBMISSION="${SCRATCH}/$(basename "${ARTIFACT}").zip"
    echo "==> Zipping $(basename "${ARTIFACT}") for submission"
    ditto -c -k --keepParent "${ARTIFACT}" "${SUBMISSION}"
fi

cleanup() {
    [ -n "${SCRATCH}" ] && rm -rf "${SCRATCH}"
    return 0
}

echo "==> Submitting $(basename "${SUBMISSION}") to Apple"
SUBMIT_JSON="$(xcrun notarytool submit "${SUBMISSION}" "${NOTARY_ARGS[@]}" --output-format json)"
SUBMIT_ID="$(printf '%s' "${SUBMIT_JSON}" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
echo "    submission id ${SUBMIT_ID}"

if ! xcrun notarytool wait "${SUBMIT_ID}" "${NOTARY_ARGS[@]}"; then
    echo "error: notarization did not complete" >&2
    cleanup
    exit 1
fi

STATUS="$(xcrun notarytool info "${SUBMIT_ID}" "${NOTARY_ARGS[@]}" --output-format json \
    | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
if [ "${STATUS}" != "Accepted" ]; then
    echo "error: notarization status was '${STATUS}'" >&2
    xcrun notarytool log "${SUBMIT_ID}" "${NOTARY_ARGS[@]}" >&2 || true
    cleanup
    exit 1
fi
cleanup

# Stapling embeds the ticket so Gatekeeper can answer offline. A zip cannot be
# stapled, which is why a .app is stapled before an image is built around it.
echo "==> Stapling $(basename "${ARTIFACT}")"
xcrun stapler staple "${ARTIFACT}"
xcrun stapler validate "${ARTIFACT}"

echo "==> Gatekeeper assessment"
if [ -d "${ARTIFACT}" ]; then
    spctl --assess --type execute --verbose=2 "${ARTIFACT}"
else
    spctl --assess --type open --context context:primary-signature --verbose=2 "${ARTIFACT}"
fi

echo "==> Notarized ${ARTIFACT}"
