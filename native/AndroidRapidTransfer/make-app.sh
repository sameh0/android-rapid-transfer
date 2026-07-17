#!/usr/bin/env bash

# Assembles the development bundle, dist/Android Rapid Transfer.app.
#
#   ./make-app.sh
#
# The bundle has the release layout (the app and Sparkle), ad-hoc signed and
# with the development bundle ID, and does not update itself unless built with
# ENABLE_UPDATES=1.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    echo "Usage: $0" >&2
    exit 2
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONFIGURATION=${CONFIGURATION:-release}
OUTPUT_DIR="$SCRIPT_DIR/dist"
# shellcheck source=Scripts/release-config.sh
source "$SCRIPT_DIR/Scripts/release-config.sh"
APP="$OUTPUT_DIR/$APP_DISPLAY_NAME.app"
CONTENTS="$APP/Contents"
EXECUTABLE="$CONTENTS/MacOS/$APP_EXECUTABLE"
MODULE_CACHE="$SCRIPT_DIR/.build/module-cache"
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
APP_VERSION_FILE="$SCRIPT_DIR/Sources/AndroidRapidTransferCore/AppVersion.swift"
APP_VERSION=$(sed -nE 's/^[[:space:]]*public static let current = "([^"]+)"/\1/p' "$APP_VERSION_FILE")

if [[ -z "$APP_VERSION" ]]; then
    echo "ERROR: Could not read AppVersion.current from $APP_VERSION_FILE" >&2
    exit 1
fi

BUILD_NUMBER=$(resolve_build_number "$REPO_ROOT")

# Development bundles do not update themselves unless asked: an update would
# silently replace a work-in-progress build. ENABLE_UPDATES=1 embeds the feed
# and key so the updater can be exercised locally.
UPDATE_KEYS=""
if [[ "${ENABLE_UPDATES:-0}" == "1" ]]; then
    UPDATE_KEYS="
    <key>SUFeedURL</key>
    <string>$SPARKLE_FEED_URL</string>
    <key>SUPublicEDKey</key>
    <string>$SPARKLE_PUBLIC_ED_KEY</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>"
fi

mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

echo "Building $APP_DISPLAY_NAME ($CONFIGURATION)..."
(
    cd "$SCRIPT_DIR"
    swift build --disable-sandbox -c "$CONFIGURATION"
)

BIN_DIR=$(
    cd "$SCRIPT_DIR"
    swift build --disable-sandbox -c "$CONFIGURATION" --show-bin-path
)
BUILT_EXECUTABLE="$BIN_DIR/$APP_EXECUTABLE"

if [[ ! -x "$BUILT_EXECUTABLE" ]]; then
    echo "ERROR: Missing SwiftPM executable: $BUILT_EXECUTABLE" >&2
    exit 1
fi

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Frameworks"
cp "$BUILT_EXECUTABLE" "$EXECUTABLE"

# Sparkle, for auto-updates. ditto keeps the framework's version symlinks.
SPARKLE_FRAMEWORK=$(sparkle_framework_source "$SCRIPT_DIR")
/usr/bin/ditto "$SPARKLE_FRAMEWORK" "$CONTENTS/Frameworks/Sparkle.framework"
sign_sparkle_framework "$CONTENTS/Frameworks/Sparkle.framework" -
if ! otool -l "$EXECUTABLE" | grep -A2 LC_RPATH | grep -Fq '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$EXECUTABLE"
fi

install_acknowledgements "$SCRIPT_DIR" "$CONTENTS"
install_app_icon "$SCRIPT_DIR" "$CONTENTS"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_EXECUTABLE</string>
    <key>CFBundleIconFile</key>
    <string>$APP_ICON_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$APP_BUNDLE_ID.dev</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_DISPLAY_NAME</string>
    <key>CFBundleName</key>
    <string>$APP_BUNDLE_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
$(exported_type_declarations)
    <key>NSHumanReadableCopyright</key>
    <string>$(copyright_notice)</string>$UPDATE_KEYS
</dict>
</plist>
PLIST

plutil -lint "$CONTENTS/Info.plist"
xattr -cr "$APP"
codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
verify_bundle_layout "$APP"

echo "SUCCESS: $APP is assembled and ad-hoc signed."
