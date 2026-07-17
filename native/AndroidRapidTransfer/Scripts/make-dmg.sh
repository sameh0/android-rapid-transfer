#!/usr/bin/env bash

# Makes release/<artifact>-<version>.dmg from the app package-release.sh built.
#
#   Scripts/make-dmg.sh
#
# Checks the app's layout (verify_bundle_layout) before making the image and
# again inside the mounted image.

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
APP_VERSION_FILE="$PROJECT_DIR/Sources/AndroidRapidTransferCore/AppVersion.swift"
HDIUTIL=/usr/bin/hdiutil

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

APP_VERSION=$(sed -nE 's/^[[:space:]]*public static let current = "([^"]+)"/\1/p' "$APP_VERSION_FILE")
[[ -n "$APP_VERSION" ]] \
    || fail "Could not read AppVersion.current from $APP_VERSION_FILE"
[[ -d "$APP" ]] || fail "Missing $APP; run Scripts/package-release.sh first."
verify_bundle_layout "$APP" \
    || fail "Refusing to make a disk image of $APP."

DMG="$RELEASE_DIR/$APP_ARTIFACT_NAME-$APP_VERSION.dmg"
CHECKSUMS="$RELEASE_DIR/SHA256SUMS"
WORK_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/art-dmg.XXXXXX")
STAGING_DIR="$WORK_DIR/staging"
MOUNT_DIR="$WORK_DIR/mount"
ATTACHED=0

cleanup() {
    if [[ "$ATTACHED" -eq 1 ]]; then
        "$HDIUTIL" detach "$MOUNT_DIR" -quiet || true
    fi
    /bin/rm -rf "$WORK_DIR"
}
trap cleanup EXIT

/bin/mkdir -p "$STAGING_DIR" "$MOUNT_DIR"
/usr/bin/ditto --norsrc "$APP" "$STAGING_DIR/$APP_DISPLAY_NAME.app"
/bin/ln -s /Applications "$STAGING_DIR/Applications"

echo "Creating $DMG..."
/bin/rm -f "$DMG"
"$HDIUTIL" create \
    -volname "$APP_DISPLAY_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov -format UDZO \
    "$DMG"

echo "Mount-testing disk image..."
"$HDIUTIL" attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT_DIR" -quiet
ATTACHED=1
[[ -d "$MOUNT_DIR/$APP_DISPLAY_NAME.app" ]] || fail "Mounted DMG is missing $APP_DISPLAY_NAME.app"
[[ -L "$MOUNT_DIR/Applications" ]] || fail "Mounted DMG is missing the Applications symlink"
verify_bundle_layout "$MOUNT_DIR/$APP_DISPLAY_NAME.app" \
    || fail "The disk image's app failed the layout check"
"$HDIUTIL" detach "$MOUNT_DIR" -quiet
ATTACHED=0

(
    cd "$RELEASE_DIR"
    /usr/bin/shasum -a 256 "$(basename "$DMG")" > "$(basename "$CHECKSUMS")"
)

echo "SUCCESS: $DMG"
echo "SHA-256: $CHECKSUMS"
