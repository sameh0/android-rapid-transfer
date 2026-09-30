#!/usr/bin/env bash

# Builds the universal release app, ad-hoc signed, into release/.
#
#   Scripts/package-release.sh
#
# The app contains only its own code, Apple's frameworks and Sparkle; the build
# fails if anything else ends up in Contents/MacOS or Contents/Frameworks.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd "$PROJECT_DIR/../.." && pwd)
RELEASE_DIR="$PROJECT_DIR/release"
# shellcheck source=release-config.sh
source "$SCRIPT_DIR/release-config.sh"
APP="$RELEASE_DIR/$APP_DISPLAY_NAME.app"
CONTENTS="$APP/Contents"
EXECUTABLE="$CONTENTS/MacOS/$APP_EXECUTABLE"
FRAMEWORKS="$CONTENTS/Frameworks"
APP_VERSION_FILE="$PROJECT_DIR/../ARTCore/Sources/AndroidRapidTransferCore/AppVersion.swift"
ENTITLEMENTS="$SCRIPT_DIR/AndroidRapidTransfer.entitlements"
MACOS_MIN_VERSION=14.0

if [[ $# -gt 0 ]]; then
    echo "Usage: $0" >&2
    exit 2
fi

LIPO=$(/usr/bin/xcrun --find lipo)
OTOOL=$(/usr/bin/xcrun --find otool)
INSTALL_NAME_TOOL=$(/usr/bin/xcrun --find install_name_tool)
CODESIGN=/usr/bin/codesign

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

require_file() {
    [[ -f "$1" ]] || fail "Missing required file: $1"
}

verify_universal() {
    local binary=$1
    local arches
    arches=$($LIPO -archs "$binary")
    [[ " $arches " == *" arm64 "* ]] || fail "$binary is missing arm64 (has: $arches)"
    [[ " $arches " == *" x86_64 "* ]] || fail "$binary is missing x86_64 (has: $arches)"
    [[ $(wc -w <<<"$arches" | tr -d ' ') -eq 2 ]] \
        || fail "$binary has unexpected architectures: $arches"
    echo "Universal: $binary ($arches)"
}

APP_VERSION=$(sed -nE 's/^[[:space:]]*public static let current = "([^"]+)"/\1/p' "$APP_VERSION_FILE")
[[ -n "$APP_VERSION" ]] \
    || fail "Could not read AppVersion.current from $APP_VERSION_FILE"

BUILD_NUMBER=$(resolve_build_number "$REPO_ROOT") || fail "Invalid build number"

require_file "$ENTITLEMENTS"

MODULE_CACHE="$PROJECT_DIR/.build/module-cache"
mkdir -p "$MODULE_CACHE" "$RELEASE_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

echo "Building $APP_DISPLAY_NAME $APP_VERSION for arm64 and x86_64..."
# -disable-sandbox also covers Swift macro plugins in restricted build hosts.
BUILD_ARGS=(-c release --arch arm64 --arch x86_64 --disable-sandbox -Xswiftc -disable-sandbox)
(
    cd "$PROJECT_DIR"
    swift build "${BUILD_ARGS[@]}"
)

# Where a multi-architecture build lands depends on the toolchain
# (.build/apple/Products/Release or .build/out/Products/Release); ask SwiftPM.
BIN_DIR=$(cd "$PROJECT_DIR" && swift build "${BUILD_ARGS[@]}" --show-bin-path)
BUILT_EXECUTABLE="$BIN_DIR/$APP_EXECUTABLE"
[[ -x "$BUILT_EXECUTABLE" ]] \
    || fail "Missing universal SwiftPM executable: $BUILT_EXECUTABLE"
verify_universal "$BUILT_EXECUTABLE"

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$FRAMEWORKS"
/bin/cp "$BUILT_EXECUTABLE" "$EXECUTABLE"
/bin/chmod u+w "$EXECUTABLE"
verify_universal "$EXECUTABLE"

# Sparkle, for auto-updates. The xcframework's macOS slice is already universal;
# ditto keeps the framework's version symlinks.
SPARKLE_FRAMEWORK=$(sparkle_framework_source "$PROJECT_DIR") || fail "Sparkle is not resolved"
/usr/bin/ditto "$SPARKLE_FRAMEWORK" "$FRAMEWORKS/Sparkle.framework"
verify_universal "$FRAMEWORKS/Sparkle.framework/Versions/B/Sparkle"

if ! "$OTOOL" -l "$EXECUTABLE" | /usr/bin/grep -A2 LC_RPATH \
    | /usr/bin/grep -Fq '@executable_path/../Frameworks'; then
    "$INSTALL_NAME_TOOL" -add_rpath '@executable_path/../Frameworks' "$EXECUTABLE"
fi
"$OTOOL" -l "$EXECUTABLE" | /usr/bin/grep -A2 LC_RPATH \
    | /usr/bin/grep -Fq '@executable_path/../Frameworks' \
    || fail "$APP_EXECUTABLE does not contain the Frameworks LC_RPATH"

install_acknowledgements "$PROJECT_DIR" "$CONTENTS" \
    || fail "Could not install the acknowledgements"
install_app_icon "$PROJECT_DIR" "$CONTENTS" \
    || fail "Could not install the app icon"

/bin/cat > "$CONTENTS/Info.plist" <<PLIST
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
    <string>$APP_BUNDLE_ID</string>
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
    <string>$MACOS_MIN_VERSION</string>
    <key>NSHighResolutionCapable</key>
    <true/>
$(exported_type_declarations)
    <key>NSHumanReadableCopyright</key>
    <string>$(copyright_notice)</string>
    <key>SUFeedURL</key>
    <string>$SPARKLE_FEED_URL</string>
    <key>SUPublicEDKey</key>
    <string>$SPARKLE_PUBLIC_ED_KEY</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$CONTENTS/Info.plist"
/usr/bin/xattr -cr "$APP"

echo "Ad-hoc signing embedded code, then the app (hardened runtime)..."
sign_sparkle_framework "$FRAMEWORKS/Sparkle.framework" - --options runtime
"$CODESIGN" --force --sign - --options runtime \
    --entitlements "$ENTITLEMENTS" "$APP"

"$CODESIGN" --verify --deep --strict --verbose=2 "$FRAMEWORKS/Sparkle.framework"
"$CODESIGN" --verify --deep --strict --verbose=2 "$APP"

verify_bundle_layout "$APP" \
    || fail "Release layout check failed"

echo "SUCCESS: $APP (version $APP_VERSION, build $BUILD_NUMBER)"
