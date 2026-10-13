#!/usr/bin/env bash

# Adds this release's DMG to the published appcast and writes the result to
# release/appcast/appcast.xml, ready to upload as a GitHub release asset.
#
#   Scripts/make-appcast.sh <release-tag> [--beta]
#
# Run after Scripts/notarize.sh, once the GitHub release <release-tag> exists
# (or will exist) with release/Android-Rapid-Transfer-<version>.dmg attached. Signing uses the
# EdDSA private key in the login keychain; the keychain may ask to allow access.
# SPARKLE_PRIVATE_KEY (the key exported by generate_keys -x), when set, is
# used instead, as CI does.
#
# Every earlier item is kept: the current appcast is downloaded from the feed
# URL (or read from APPCAST_BASE, a local file) and generate_appcast only adds
# the new archive. --beta publishes the item on the beta channel, which only
# builds with "Include beta releases" turned on can see.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
RELEASE_DIR="$PROJECT_DIR/release"
APP_VERSION_FILE="$PROJECT_DIR/../ARTCore/Sources/AndroidRapidTransferCore/AppVersion.swift"
WORK_DIR="$RELEASE_DIR/appcast"

# shellcheck source=release-config.sh
source "$SCRIPT_DIR/release-config.sh"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    echo "Usage: $0 <release-tag> [--beta]" >&2
    exit 2
}

[[ $# -ge 1 ]] || usage
TAG=$1
shift
CHANNEL_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --beta) CHANNEL_ARGS=(--channel beta) ;;
        *) usage ;;
    esac
    shift
done
[[ "$TAG" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Release tag contains unsupported characters: $TAG"

APP_VERSION=$(sed -nE 's/^[[:space:]]*public static let current = "([^"]+)"/\1/p' "$APP_VERSION_FILE")
[[ -n "$APP_VERSION" ]] || fail "Could not read AppVersion.current from $APP_VERSION_FILE"
DMG="$RELEASE_DIR/$APP_ARTIFACT_NAME-$APP_VERSION.dmg"
[[ -f "$DMG" ]] || fail "Missing $DMG; run Scripts/package-release.sh and Scripts/notarize.sh first."

# Publishing gate: the app in the DMG must have the expected layout.
CHECK_MOUNT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/art-appcast-check.XXXXXX")
/usr/bin/hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$CHECK_MOUNT" -quiet \
    || fail "Could not mount $DMG to check it"
if ! verify_bundle_layout "$CHECK_MOUNT/$APP_DISPLAY_NAME.app"; then
    /usr/bin/hdiutil detach "$CHECK_MOUNT" -quiet || true
    fail "Refusing to publish $DMG."
fi
/usr/bin/hdiutil detach "$CHECK_MOUNT" -quiet
/bin/rmdir "$CHECK_MOUNT"

GENERATE_APPCAST="$(sparkle_tools_dir "$PROJECT_DIR")/generate_appcast"
[[ -x "$GENERATE_APPCAST" ]] || fail "Missing $GENERATE_APPCAST; resolve packages with swift build first."

# GitHub serves each release's assets from its own tag.
REPOSITORY_URL=${SPARKLE_FEED_URL%/releases/latest/download/appcast.xml}
[[ "$REPOSITORY_URL" != "$SPARKLE_FEED_URL" ]] \
    || fail "SPARKLE_FEED_URL is not a GitHub releases/latest URL: $SPARKLE_FEED_URL"
DOWNLOAD_PREFIX="$REPOSITORY_URL/releases/download/$TAG/"

/bin/rm -rf "$WORK_DIR"
/bin/mkdir -p "$WORK_DIR"

if [[ -n "${APPCAST_BASE:-}" ]]; then
    /bin/cp "$APPCAST_BASE" "$WORK_DIR/appcast.xml"
    echo "Starting from $APPCAST_BASE"
elif /usr/bin/curl -fsSL "$SPARKLE_FEED_URL" -o "$WORK_DIR/appcast.xml"; then
    echo "Starting from the published appcast at $SPARKLE_FEED_URL"
else
    /bin/rm -f "$WORK_DIR/appcast.xml"
    echo "No published appcast found; starting a new one."
fi

/bin/cp "$DMG" "$WORK_DIR/"
# Optional release notes: release/Android-Rapid-Transfer-<version>.html sits next to the DMG.
NOTES="$RELEASE_DIR/$APP_ARTIFACT_NAME-$APP_VERSION.html"
[[ -f "$NOTES" ]] && /bin/cp "$NOTES" "$WORK_DIR/"

GENERATE_ARGS=(
    --download-url-prefix "$DOWNLOAD_PREFIX"
    --maximum-versions 0
    --maximum-deltas 0
    ${CHANNEL_ARGS[@]+"${CHANNEL_ARGS[@]}"}
    "$WORK_DIR"
)
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    # CI: the exported key (generate_keys -x) arrives in the environment and is
    # handed to generate_appcast on standard input, never written to disk.
    printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$GENERATE_APPCAST" --ed-key-file - "${GENERATE_ARGS[@]}"
else
    "$GENERATE_APPCAST" "${GENERATE_ARGS[@]}"
fi

[[ -f "$WORK_DIR/appcast.xml" ]] || fail "generate_appcast did not write appcast.xml"
/usr/bin/grep -Fq "$DOWNLOAD_PREFIX$(basename "$DMG")" "$WORK_DIR/appcast.xml" \
    || fail "appcast.xml has no item for $(basename "$DMG")"
/usr/bin/grep -Fq 'sparkle:edSignature' "$WORK_DIR/appcast.xml" \
    || fail "appcast.xml items are not EdDSA-signed"

echo "SUCCESS: $WORK_DIR/appcast.xml"
echo "Upload it to the latest non-prerelease GitHub release, replacing the old one."
