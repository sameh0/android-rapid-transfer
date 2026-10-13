#!/usr/bin/env bash

# Developer ID signs the app package-release.sh built, makes its DMG and
# notarizes it. It needs the Developer ID and notarization credentials in the environment.
#
#   Scripts/notarize.sh
#
# Checks the app's layout (verify_bundle_layout) before touching credentials
# or signatures.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    echo "Usage: $0" >&2
    exit 2
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
RELEASE_DIR="$PROJECT_DIR/release"
# shellcheck source=release-config.sh
source "$SCRIPT_DIR/release-config.sh"
APP="$RELEASE_DIR/$APP_DISPLAY_NAME.app"
FRAMEWORKS="$APP/Contents/Frameworks"
APP_VERSION_FILE="$PROJECT_DIR/../ARTCore/Sources/AndroidRapidTransferCore/AppVersion.swift"

[[ -d "$APP" ]] || { echo "ERROR: Missing $APP; run Scripts/package-release.sh first." >&2; exit 1; }
# Checked before anything else, credentials included.
verify_bundle_layout "$APP" || {
    echo "ERROR: Refusing to sign or notarize $APP." >&2
    exit 1
}

# notarytool authenticates with an Apple ID and app-specific password, or with
# an App Store Connect API key (NOTARY_API_KEY_PATH/_ID/ISSUER_ID) when all
# three of those are set.
if [[ -n "${NOTARY_API_KEY_PATH:-}" && -n "${NOTARY_API_KEY_ID:-}" && -n "${NOTARY_API_ISSUER_ID:-}" ]]; then
    required=(DEVELOPER_ID_APP)
    [[ -f "$NOTARY_API_KEY_PATH" ]] \
        || { echo "ERROR: NOTARY_API_KEY_PATH is not a file: $NOTARY_API_KEY_PATH" >&2; exit 1; }
    NOTARY_AUTH=(--key "$NOTARY_API_KEY_PATH" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER_ID")
else
    required=(DEVELOPER_ID_APP APPLE_ID TEAM_ID APP_PASSWORD)
    NOTARY_AUTH=(--apple-id "${APPLE_ID:-}" --team-id "${TEAM_ID:-}" --password "${APP_PASSWORD:-}")
fi

missing=()
for variable in "${required[@]}"; do
    [[ -n "${!variable:-}" ]] || missing+=("$variable")
done

if [[ ${#missing[@]} -ne 0 ]]; then
    echo "ERROR: Notarization is locked by the Phase 6 credential gate." >&2
    echo "Set all required environment variables: DEVELOPER_ID_APP, APPLE_ID, TEAM_ID, APP_PASSWORD" >&2
    echo "(or DEVELOPER_ID_APP with NOTARY_API_KEY_PATH, NOTARY_API_KEY_ID, NOTARY_API_ISSUER_ID)." >&2
    echo "Missing: ${missing[*]}" >&2
    echo "No signing or notarization work was performed." >&2
    exit 1
fi


APP_VERSION=$(sed -nE 's/^[[:space:]]*public static let current = "([^"]+)"/\1/p' "$APP_VERSION_FILE")
[[ -n "$APP_VERSION" ]] || { echo "ERROR: Could not read AppVersion.current." >&2; exit 1; }

echo "Developer ID signing embedded code, then the app..."
# Library validation is on in a Developer ID build, so Sparkle must carry the
# same team signature as the app.
sign_sparkle_framework "$FRAMEWORKS/Sparkle.framework" "$DEVELOPER_ID_APP" \
    --timestamp --options runtime
# Same-team Developer ID signatures replace the ad-hoc library-validation exception.
/usr/bin/codesign --force --timestamp --options runtime \
    --sign "$DEVELOPER_ID_APP" "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

"$SCRIPT_DIR/make-dmg.sh"
DMG="$RELEASE_DIR/$APP_ARTIFACT_NAME-$APP_VERSION.dmg"

# Gatekeeper assesses a downloaded DMG by its own signature (spctl --type open),
# so the image is signed too, before notarization.
echo "Developer ID signing the DMG..."
/usr/bin/codesign --force --timestamp --sign "$DEVELOPER_ID_APP" "$DMG"
/usr/bin/codesign --verify --strict --verbose=2 "$DMG"

echo "Submitting $DMG to Apple's notary service..."
/usr/bin/xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait

echo "Stapling and validating the notarization ticket..."
/usr/bin/xcrun stapler staple "$DMG"
/usr/bin/xcrun stapler validate "$DMG"

(
    cd "$RELEASE_DIR"
    /usr/bin/shasum -a 256 "$(basename "$DMG")" > SHA256SUMS
)

echo "SUCCESS: signed and notarized $DMG"
