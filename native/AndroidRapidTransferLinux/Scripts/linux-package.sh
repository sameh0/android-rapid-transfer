#!/usr/bin/env bash

# Makes the Linux release artifacts from the tree Scripts/linux-build.sh staged.
#
#   Scripts/linux-package.sh [--stage DIR] [--output DIR] <format>...
#
#   tarball   Android-Rapid-Transfer-<version>-linux-<arch>.tar.gz: bin/, share/,
#             lib/udev/ and install.sh (Scripts/linux-install.sh) in one folder
#   appimage  Android-Rapid-Transfer-<version>-<arch>.AppImage (+ .zsync), with
#             the static type2 runtime: no FUSE 2 needed. It uses the system's
#             GTK 4 and libadwaita rather than bundling them.
#   deb       android-rapid-transfer_<version>-1_<arch>.deb (nfpm)
#   rpm       android-rapid-transfer-<version>-1.<arch>.rpm (nfpm)
#   all       all four
#
#   --stage    the staged tree (default dist/stage; built by linux-build.sh if missing)
#   --output   where the artifacts go (default dist)
#
# appimagetool, its runtime and nfpm are downloaded once, pinned by checksum
# (Scripts/linux-tools.sh); an nfpm on PATH is used when it is the pinned
# version. Every artifact is checked after it is made.
#
# Environment: ART_PACKAGE_RELEASE (package revision, default 1),
# LINUX_MAINTAINER (overrides the .deb/.rpm maintainer),
# SOURCE_DATE_EPOCH (timestamps; default: the last commit's time).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd "$PROJECT_DIR/../.." && pwd)
PACKAGING_DIR="$PROJECT_DIR/packaging"
# shellcheck source=linux-release-config.sh
source "$SCRIPT_DIR/linux-release-config.sh"
# shellcheck source=linux-tools.sh
source "$SCRIPT_DIR/linux-tools.sh"

STAGE="$PROJECT_DIR/dist/stage"
OUTPUT="$PROJECT_DIR/dist"
FORMATS=()

usage() {
    sed -n '/^#   Scripts\/linux-package.sh/,/^#   --output/p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage) STAGE=${2:?}; shift ;;
        --output) OUTPUT=${2:?}; shift ;;
        tarball | appimage | deb | rpm) FORMATS+=("$1") ;;
        all) FORMATS+=(tarball appimage deb rpm) ;;
        -h | --help) usage ;;
        *) echo "Unknown argument $1" >&2; usage ;;
    esac
    shift
done
[[ ${#FORMATS[@]} -gt 0 ]] || usage

note() { echo "==> $*"; }
ok() { echo "    ok  $*"; }
fail() {
    echo "ERROR: $*" >&2
    [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::error title=linux-package::$*"
    exit 1
}

if [[ ! -x "$STAGE/usr/bin/$LINUX_EXECUTABLE" ]]; then
    note "No staged build in $STAGE; running Scripts/linux-build.sh..."
    "$SCRIPT_DIR/linux-build.sh" --stage "$STAGE"
fi
STAGE=$(cd "$STAGE" && pwd)
VERSION=$(cat "$STAGE/VERSION")
mkdir -p "$OUTPUT"
OUTPUT=$(cd "$OUTPUT" && pwd)
BINARY="$STAGE/usr/bin/$LINUX_EXECUTABLE"

ARCH=$(uname -m)
case "$ARCH" in
    x86_64) DEB_ARCH=amd64 ;;
    aarch64) DEB_ARCH=arm64 ;;
    *) fail "Unsupported architecture $ARCH" ;;
esac

export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$REPO_ROOT" log -1 --format=%ct 2>/dev/null || date +%s)}

# The newest glibc symbol version the binary uses: its minimum glibc.
glibc_minimum() {
    objdump -T "$BINARY" | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -n 1
}
GLIBC_MIN=$(glibc_minimum)
[[ -n "$GLIBC_MIN" ]] || fail "Could not read the glibc symbol versions of $BINARY"

# --- tarball --------------------------------------------------------------------

make_tarball() {
    local name="$LINUX_ARTIFACT_NAME-$VERSION-linux-$ARCH"
    local work tarball="$OUTPUT/$name.tar.gz"
    note "Making $(basename "$tarball")..."
    work=$(mktemp -d)
    mkdir -p "$work/$name"
    cp -a "$STAGE/usr/." "$work/$name/"
    install -m755 "$SCRIPT_DIR/linux-install.sh" "$work/$name/install.sh"
    install -m644 "$SCRIPT_DIR/linux-release-config.sh" "$work/$name/linux-release-config.sh"
    cat >"$work/$name/README" <<README
$LINUX_APP_NAME $VERSION for Linux ($ARCH)

Install for yourself (into ~/.local):   ./install.sh
Install for everyone (into /usr/local): sudo ./install.sh --prefix /usr/local
Uninstall:                              ./install.sh --uninstall [--prefix ...]
Or run it in place:                     ./bin/$LINUX_EXECUTABLE

Needs GTK $LINUX_MIN_GTK or later, libadwaita $LINUX_MIN_ADWAITA or later and glibc $GLIBC_MIN or later.
See share/doc/$LINUX_PACKAGE_NAME/README about USB access to the phone.
README
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$SOURCE_DATE_EPOCH" \
        -C "$work" -czf "$tarball" "$name"
    rm -rf "$work"

    # Check: the listing, then an install from the unpacked tarball.
    local listing
    listing=$(tar -tzf "$tarball")
    local expected
    for expected in "$name/install.sh" "$name/bin/$LINUX_EXECUTABLE" \
        "$name/share/applications/$LINUX_APP_ID.desktop" \
        "$name/share/icons/hicolor/scalable/apps/$LINUX_APP_ID.svg" \
        "$name/lib/udev/rules.d/70-$LINUX_PACKAGE_NAME.rules"; do
        grep -qx "$expected" <<<"$listing" || fail "$(basename "$tarball") has no $expected"
    done
    work=$(mktemp -d)
    tar -xzf "$tarball" -C "$work"
    "$work/$name/install.sh" --prefix "$work/prefix" >/dev/null
    [[ -x "$work/prefix/bin/$LINUX_EXECUTABLE" ]] || fail "install.sh from the tarball did not install the binary"
    "$work/$name/install.sh" --prefix "$work/prefix" --uninstall >/dev/null
    [[ ! -e "$work/prefix/bin/$LINUX_EXECUTABLE" ]] || fail "install.sh --uninstall left the binary"
    rm -rf "$work"
    ok "$(basename "$tarball"): contents, install.sh and --uninstall"
}

# --- AppImage -------------------------------------------------------------------

make_appimage() {
    local name="$LINUX_ARTIFACT_NAME-$VERSION-$ARCH.AppImage"
    local appimage="$OUTPUT/$name" appdir tool runtime
    note "Making $name..."
    tool=$(fetch_tool "appimagetool_$ARCH")
    runtime=$(fetch_tool "appimage_runtime_$ARCH")
    chmod +x "$tool"

    appdir=$(mktemp -d)/AppDir
    mkdir -p "$appdir"
    cp -a "$STAGE/usr" "$appdir/usr"
    cat >"$appdir/AppRun" <<'APPRUN'
#!/bin/sh
# The app needs the system's GTK 4 and libadwaita (they are not bundled).
HERE=$(dirname "$(readlink -f "$0")")
exec "$HERE/usr/bin/android-rapid-transfer" "$@"
APPRUN
    chmod 755 "$appdir/AppRun"
    cp "$STAGE/usr/share/applications/$LINUX_APP_ID.desktop" "$appdir/"
    cp "$STAGE/usr/share/icons/hicolor/scalable/apps/$LINUX_APP_ID.svg" "$appdir/"
    cp "$STAGE/usr/share/icons/hicolor/256x256/apps/$LINUX_APP_ID.png" "$appdir/.DirIcon"

    rm -f "$appimage" "$appimage.zsync"
    # APPIMAGE_EXTRACT_AND_RUN: appimagetool is itself an AppImage, and CI
    # containers have no FUSE.
    (
        cd "$OUTPUT"
        export ARCH APPIMAGE_EXTRACT_AND_RUN=1
        "$tool" \
            --runtime-file "$runtime" \
            --updateinformation "gh-releases-zsync|sameh0|android-rapid-transfer|latest|$LINUX_ARTIFACT_NAME-*-$ARCH.AppImage.zsync" \
            "$appdir" "$appimage"
    ) || fail "appimagetool failed"
    rm -rf "$(dirname "$appdir")"

    # Check: the runtime and the payload.
    [[ -x "$appimage" ]] || fail "$name is missing or not executable"
    local work
    work=$(mktemp -d)
    (cd "$work" && "$appimage" --appimage-extract >/dev/null) || fail "$name --appimage-extract failed"
    [[ -x "$work/squashfs-root/usr/bin/$LINUX_EXECUTABLE" && -x "$work/squashfs-root/AppRun" ]] \
        || fail "$name does not contain AppRun and usr/bin/$LINUX_EXECUTABLE"
    cmp -s "$work/squashfs-root/usr/bin/$LINUX_EXECUTABLE" "$BINARY" || fail "$name holds a different binary"
    rm -rf "$work"
    "$appimage" --appimage-updateinformation | grep -q '^gh-releases-zsync|' \
        || fail "$name has no update information"
    ok "$name: runtime, payload and update information"
}

# --- deb / rpm ------------------------------------------------------------------

nfpm_binary() {
    if command -v nfpm >/dev/null && nfpm --version 2>&1 | grep -q 'GitVersion: *v\{0,1\}2\.47\.0'; then
        command -v nfpm
        return
    fi
    local archive dir
    archive=$(fetch_tool "nfpm_$ARCH")
    dir="$(dirname "$archive")/bin"
    if [[ ! -x "$dir/nfpm" ]]; then
        mkdir -p "$dir"
        tar -xzf "$archive" -C "$dir" nfpm
    fi
    echo "$dir/nfpm"
}

make_nfpm() {
    local packager=$1 nfpm target
    nfpm=$(nfpm_binary)
    case "$packager" in
        deb) target="$OUTPUT/${LINUX_PACKAGE_NAME}_${VERSION//-/\~}-${ART_PACKAGE_RELEASE:-1}_$DEB_ARCH.deb" ;;
        rpm) target="$OUTPUT/$LINUX_PACKAGE_NAME-${VERSION//-/\~}-${ART_PACKAGE_RELEASE:-1}.$ARCH.rpm" ;;
    esac
    note "Making $(basename "$target") (glibc >= $GLIBC_MIN, GTK >= $LINUX_MIN_GTK, libadwaita >= $LINUX_MIN_ADWAITA)..."
    rm -f "$target"
    # nfpm expands environment variables in only some fields, so the
    # ${...} placeholders in packaging/nfpm.yaml are filled in here.
    local -A values=(
        [NFPM_ARCH]=$DEB_ARCH
        [ART_VERSION]=$VERSION
        [ART_PACKAGE_RELEASE]=${ART_PACKAGE_RELEASE:-1}
        [ART_MAINTAINER]=$LINUX_MAINTAINER
        [ART_STAGE]=$STAGE
        [ART_PACKAGING]=$PACKAGING_DIR
        [ART_GLIBC_MIN]=$GLIBC_MIN
        [ART_MIN_GTK]=$LINUX_MIN_GTK
        [ART_MIN_ADWAITA]=$LINUX_MIN_ADWAITA
    )
    local content key config
    content=$(<"$PACKAGING_DIR/nfpm.yaml")
    for key in "${!values[@]}"; do
        content=${content//"\${$key}"/${values[$key]}}
    done
    [[ ! "$content" =~ \$\{[A-Z_]+\} ]] || fail "packaging/nfpm.yaml has a placeholder linux-package.sh does not fill in"
    config=$(mktemp --suffix=.yaml)
    printf '%s\n' "$content" >"$config"
    "$nfpm" package --config "$config" --packager "$packager" --target "$target" \
        || fail "nfpm failed to make the $packager"
    rm -f "$config"
    [[ -s "$target" ]] || fail "nfpm did not produce $target"
    "verify_$packager" "$target"
}

verify_deb() {
    local deb=$1 info contents
    if ! command -v dpkg-deb >/dev/null; then
        echo "    --  dpkg-deb not installed; $(basename "$deb") not inspected"
        return
    fi
    info=$(dpkg-deb --info "$deb")
    contents=$(dpkg-deb --contents "$deb")
    grep -q "Package: $LINUX_PACKAGE_NAME" <<<"$info" || fail "$(basename "$deb"): wrong package name"
    grep -q "libadwaita-1-0 (>= $LINUX_MIN_ADWAITA)" <<<"$info" || fail "$(basename "$deb"): no libadwaita dependency"
    grep -q "libgtk-4-1 (>= $LINUX_MIN_GTK)" <<<"$info" || fail "$(basename "$deb"): no GTK dependency"
    grep -q "\./usr/bin/$LINUX_EXECUTABLE\$" <<<"$contents" || fail "$(basename "$deb"): no binary"
    grep -q "\./usr/lib/udev/rules.d/70-$LINUX_PACKAGE_NAME.rules\$" <<<"$contents" || fail "$(basename "$deb"): no udev rule"
    grep -q "\./usr/share/icons/hicolor/scalable/apps/$LINUX_APP_ID.svg\$" <<<"$contents" || fail "$(basename "$deb"): no icon"
    echo "$info" | sed -n '/^ Depends:/p;/^ Version:/p' | sed 's/^ /    /'
    ok "$(basename "$deb"): metadata and contents"
}

verify_rpm() {
    local rpm_file=$1 contents requires
    if ! command -v rpm >/dev/null; then
        echo "    --  rpm not installed; $(basename "$rpm_file") not inspected"
        return
    fi
    contents=$(rpm -qlp "$rpm_file" 2>/dev/null)
    requires=$(rpm -qp --requires "$rpm_file" 2>/dev/null)
    grep -qx "/usr/bin/$LINUX_EXECUTABLE" <<<"$contents" || fail "$(basename "$rpm_file"): no binary"
    grep -qx "/usr/lib/udev/rules.d/70-$LINUX_PACKAGE_NAME.rules" <<<"$contents" || fail "$(basename "$rpm_file"): no udev rule"
    grep -q "^libadwaita >= $LINUX_MIN_ADWAITA" <<<"$requires" || fail "$(basename "$rpm_file"): no libadwaita requirement"
    echo "    Requires: $(grep -v '^rpmlib' <<<"$requires" | paste -sd, | sed 's/,/, /g')"
    ok "$(basename "$rpm_file"): metadata and contents"
}

for format in "${FORMATS[@]}"; do
    case "$format" in
        tarball) make_tarball ;;
        appimage) make_appimage ;;
        deb | rpm) make_nfpm "$format" ;;
    esac
done
note "Artifacts in $OUTPUT:"
(cd "$OUTPUT" && ls -l -- *.tar.gz *.AppImage *.zsync *.deb *.rpm 2>/dev/null || true)
