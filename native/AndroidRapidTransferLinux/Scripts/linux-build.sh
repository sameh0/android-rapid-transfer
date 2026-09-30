#!/usr/bin/env bash

# Builds the Linux app in release mode and stages it as an installed tree:
#
#   <stage>/usr/bin/android-rapid-transfer
#   <stage>/usr/share/applications/com.sameh.AndroidRapidTransfer.desktop
#   <stage>/usr/share/metainfo/com.sameh.AndroidRapidTransfer.metainfo.xml
#   <stage>/usr/share/icons/hicolor/{scalable,16x16,...,512x512}/apps/com.sameh.AndroidRapidTransfer.{svg,png}
#   <stage>/usr/lib/udev/rules.d/70-android-rapid-transfer.rules
#   <stage>/usr/share/doc/android-rapid-transfer/{LICENSE,README}
#
# Every package (tarball, AppImage, .deb, .rpm; Scripts/linux-package.sh) and
# Scripts/linux-install.sh is made from that tree.
#
#   Scripts/linux-build.sh [--product NAME] [--stage DIR] [--scratch-path DIR]
#                          [--skip-build] [--no-strip] [--check-only]
#
#   --product      SwiftPM executable product to build (default
#                  android-rapid-transfer; env ART_LINUX_PRODUCT). It is always
#                  installed as usr/bin/android-rapid-transfer, so another
#                  product (art-gtk-demo) can stand in for the app.
#   --stage        output directory (default dist/stage; it is emptied)
#   --scratch-path SwiftPM build directory (default .build; env ART_LINUX_SCRATCH_PATH)
#   --skip-build   stage the binary a previous build left in the scratch path
#   --no-strip     keep debug information in the staged binary
#   --check-only   only validate the desktop entry, AppStream metadata, udev
#                  rule and icons (no build)
#
# The Swift runtime is linked statically (--static-swift-stdlib), so the binary
# needs only glibc, libstdc++ and the system's GTK 4 and libadwaita.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
NATIVE_DIR=$(cd "$PROJECT_DIR/.." && pwd)
REPO_ROOT=$(cd "$NATIVE_DIR/.." && pwd)
PACKAGING_DIR="$PROJECT_DIR/packaging"
APP_VERSION_FILE="$NATIVE_DIR/ARTCore/Sources/AndroidRapidTransferCore/AppVersion.swift"
# shellcheck source=linux-release-config.sh
source "$SCRIPT_DIR/linux-release-config.sh"

PRODUCT=${ART_LINUX_PRODUCT:-$LINUX_PRODUCT}
STAGE="$PROJECT_DIR/dist/stage"
SCRATCH=${ART_LINUX_SCRATCH_PATH:-$PROJECT_DIR/.build}
BUILD=1
STRIP=1
CHECK_ONLY=0

usage() {
    sed -n '/^#   Scripts/,/^#                  rule and icons/p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --product) PRODUCT=${2:?}; shift ;;
        --stage) STAGE=${2:?}; shift ;;
        --scratch-path) SCRATCH=${2:?}; shift ;;
        --skip-build) BUILD=0 ;;
        --no-strip) STRIP=0 ;;
        --check-only) CHECK_ONLY=1 ;;
        -h | --help) usage ;;
        *) echo "Unknown option $1" >&2; usage ;;
    esac
    shift
done

note() { echo "==> $*"; }
fail() {
    echo "ERROR: $*" >&2
    [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::error title=linux-build::$*"
    exit 1
}

app_version() {
    local version
    version=$(sed -nE 's/^[[:space:]]*public static let current = "([^"]+)"/\1/p' "$APP_VERSION_FILE")
    [[ -n "$version" ]] || fail "Could not read AppVersion.current from $APP_VERSION_FILE"
    echo "$version"
}

APP_VERSION=$(app_version)
DESKTOP="$PACKAGING_DIR/$LINUX_APP_ID.desktop"
METAINFO="$PACKAGING_DIR/$LINUX_APP_ID.metainfo.xml"
UDEV_RULE="$PACKAGING_DIR/70-$LINUX_PACKAGE_NAME.rules"
ICONS="$PACKAGING_DIR/icons/hicolor"

# --- metadata -----------------------------------------------------------------

check_metadata() {
    note "Checking the desktop entry, AppStream metadata and icons..."
    local file
    for file in "$DESKTOP" "$METAINFO" "$UDEV_RULE" "$ICONS/scalable/apps/$LINUX_APP_ID.svg"; do
        [[ -f "$file" ]] || fail "Missing $file"
    done
    grep -qx "Exec=$LINUX_EXECUTABLE" "$DESKTOP" || fail "$DESKTOP must have Exec=$LINUX_EXECUTABLE"
    grep -qx "Icon=$LINUX_APP_ID" "$DESKTOP" || fail "$DESKTOP must have Icon=$LINUX_APP_ID"
    grep -qx "StartupWMClass=$LINUX_APP_ID" "$DESKTOP" || fail "$DESKTOP must have StartupWMClass=$LINUX_APP_ID"
    grep -q "<id>$LINUX_APP_ID</id>" "$METAINFO" || fail "$METAINFO must have <id>$LINUX_APP_ID</id>"
    # The newest release listed is the one being built.
    local listed
    listed=$(sed -nE 's/.*<release version="([^"]+)".*/\1/p' "$METAINFO" | head -n 1)
    [[ "$listed" == "$APP_VERSION" ]] \
        || fail "The newest <release> in $(basename "$METAINFO") is '$listed', but AppVersion.current is $APP_VERSION; add a <release> entry."

    if command -v desktop-file-validate >/dev/null; then
        local report
        report=$(desktop-file-validate "$DESKTOP" 2>&1) || { echo "$report" >&2; fail "desktop-file-validate failed"; }
        # Hints (such as "FileTransfer can be extended with Network") are not
        # problems; warnings and errors are.
        report=$(grep -v ': hint: ' <<<"$report" || true)
        [[ -z "$report" ]] || { echo "$report" >&2; fail "desktop-file-validate reported problems"; }
        echo "    ok  desktop-file-validate"
    else
        echo "    --  desktop-file-validate not installed; skipped"
    fi
    if command -v appstreamcli >/dev/null; then
        appstreamcli validate --no-net --explain "$METAINFO" >/dev/null || {
            appstreamcli validate --no-net --explain "$METAINFO" || true
            fail "appstreamcli validate failed"
        }
        echo "    ok  appstreamcli validate"
    else
        echo "    --  appstreamcli not installed; skipped"
    fi
    if command -v udevadm >/dev/null && udevadm verify --help >/dev/null 2>&1; then
        udevadm verify --no-style "$UDEV_RULE" >/dev/null || fail "udevadm verify failed for $UDEV_RULE"
        echo "    ok  udevadm verify"
    fi
    if command -v python3 >/dev/null && command -v rsvg-convert >/dev/null; then
        python3 "$SCRIPT_DIR/make-linux-icons.py" --check >/dev/null \
            || fail "The icons in packaging/icons are out of date; run Scripts/make-linux-icons.py"
        echo "    ok  icons match Scripts/make-linux-icons.py"
    else
        echo "    --  python3 or rsvg-convert not installed; icon check skipped"
    fi
}

# --- build ----------------------------------------------------------------------

build_binary() {
    if [[ "$BUILD" == 1 ]]; then
        note "Building $PRODUCT (release, static Swift runtime)..."
        swift build \
            --package-path "$PROJECT_DIR" \
            --scratch-path "$SCRATCH" \
            --configuration release \
            --product "$PRODUCT" \
            --static-swift-stdlib \
            || fail "swift build failed"
    fi
    BIN_DIR=$(swift build --package-path "$PROJECT_DIR" --scratch-path "$SCRATCH" --configuration release --show-bin-path)
    BINARY="$BIN_DIR/$PRODUCT"
    [[ -x "$BINARY" ]] || fail "No $BINARY; build without --skip-build first"
}

# --- stage ----------------------------------------------------------------------

stage_tree() {
    local resolved
    mkdir -p "$STAGE"
    resolved=$(cd "$STAGE" && pwd -P)
    case "$resolved" in
        / | "$(cd "$HOME" && pwd -P)" | "$(cd "$REPO_ROOT" && pwd -P)" | "$(cd "$PROJECT_DIR" && pwd -P)")
            fail "--stage must be a dedicated directory (it is emptied); got $STAGE" ;;
    esac
    rm -rf "$STAGE"
    note "Staging into $STAGE..."
    local usr="$STAGE/usr"
    install -Dm755 "$BINARY" "$usr/bin/$LINUX_EXECUTABLE"
    if [[ "$STRIP" == 1 ]]; then
        strip --strip-unneeded "$usr/bin/$LINUX_EXECUTABLE"
    fi
    install -Dm644 "$DESKTOP" "$usr/share/applications/$LINUX_APP_ID.desktop"
    install -Dm644 "$METAINFO" "$usr/share/metainfo/$LINUX_APP_ID.metainfo.xml"
    local icon
    while IFS= read -r icon; do
        install -Dm644 "$ICONS/$icon" "$usr/share/icons/hicolor/$icon"
    done < <(cd "$ICONS" && find . -type f -name "$LINUX_APP_ID.*" | sed 's|^\./||' | sort)
    install -Dm644 "$UDEV_RULE" "$usr/lib/udev/rules.d/$(basename "$UDEV_RULE")"
    install -Dm644 "$REPO_ROOT/LICENSE" "$usr/share/doc/$LINUX_PACKAGE_NAME/LICENSE"
    cat >"$usr/share/doc/$LINUX_PACKAGE_NAME/README" <<README
$LINUX_APP_NAME $APP_VERSION for Linux
$LINUX_HOMEPAGE

Needs GTK $LINUX_MIN_GTK or later and libadwaita $LINUX_MIN_ADWAITA or later.

Phones in File transfer (MTP) mode are opened directly over USB. On systemd
desktops the logged-in user already has access to nearly every Android phone.
If the app says Linux isn't letting it open the phone, install the udev rule
in lib/udev/rules.d (packages do this for you) into /etc/udev/rules.d, run
  sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=usb
and plug the phone in again.
README
    printf '%s\n' "$APP_VERSION" >"$STAGE/VERSION"
    printf '%s\n' "$PRODUCT" >"$STAGE/PRODUCT"
}

# --- verify ---------------------------------------------------------------------

verify_binary() {
    local binary="$STAGE/usr/bin/$LINUX_EXECUTABLE" needed missing
    note "Checking $LINUX_EXECUTABLE's libraries..."
    file "$binary" | sed 's/^/    /'
    needed=$(readelf -d "$binary" | sed -nE 's/.*\(NEEDED\).*\[(.*)\]/\1/p')
    echo "    NEEDED: $(tr '\n' ' ' <<<"$needed")"
    if grep -q '^libswift\|^libFoundation\|^libdispatch\|^libBlocksRuntime' <<<"$needed"; then
        fail "The binary links the Swift runtime dynamically; it must be built with --static-swift-stdlib"
    fi
    missing=$(ldd "$binary" | grep 'not found' || true)
    [[ -z "$missing" ]] || fail "Unresolved libraries:"$'\n'"$missing"
    echo "    ok  ldd: every library resolves"
    local size
    size=$(du -h "$binary" | cut -f1)
    echo "    ok  $size, $(uname -m)"
}

check_metadata
if [[ "$CHECK_ONLY" == 1 ]]; then
    exit 0
fi
build_binary
stage_tree
verify_binary
note "Staged $LINUX_APP_NAME $APP_VERSION ($PRODUCT) in $STAGE"
