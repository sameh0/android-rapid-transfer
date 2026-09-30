#!/usr/bin/env bash

# Prepares a fresh Ubuntu 26.04 container (as root) to build, test and package
# the Linux app: the build and test packages, then the Swift toolchain.
#
#   Scripts/linux-ci-setup.sh [--no-apt] [--toolchain-dir DIR]
#
# Why not the official swift:6.3 images: the newest of them is Ubuntu 24.04,
# whose libadwaita (1.5) and GTK (4.14) are older than the app needs (see
# PACKAGING.md), and no Swift 6.3 build exists for Ubuntu 26.04. So this
# installs the official Swift 6.3 build for Ubuntu 24.04, checked against a
# pinned SHA-256, and supplies the one library its tools need that 26.04 no
# longer ships: libxml2.so.2 (26.04 has libxml2.so.16), with the ICU it links,
# unpacked from the Ubuntu 24.04 packages into a private directory.
#
# Environment:
#   ART_SWIFT_TARBALL   an already-downloaded Swift tarball (skips the download;
#                       it must still match the pinned checksum)
#   ART_LINUX_TOOLS_DIR download cache (default ~/.cache/art-linux-tools)
#   GITHUB_PATH         when set (GitHub Actions), the toolchain's bin directory
#                       is added to it for later steps

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=linux-release-config.sh
source "$SCRIPT_DIR/linux-release-config.sh"
# shellcheck source=linux-tools.sh
source "$SCRIPT_DIR/linux-tools.sh"

APT=1
TOOLCHAIN_ROOT=/opt/swift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-apt) APT=0 ;;
        --toolchain-dir) TOOLCHAIN_ROOT=$2; shift ;;
        *) echo "Usage: $0 [--no-apt] [--toolchain-dir DIR]" >&2; exit 2 ;;
    esac
    shift
done

note() { echo "==> $*"; }

# Build: Swift's own requirements (as in the official images) plus GTK 4 and
# libadwaita. Test: Xvfb for the GTK self-test. Package: the validators and
# inspectors the packaging scripts run when present.
APT_PACKAGES=(
    ca-certificates curl git gnupg tzdata unzip xz-utils file
    binutils build-essential libc6-dev libcurl4-openssl-dev libedit2 libncurses-dev
    libsqlite3-0 libz3-dev pkg-config zlib1g-dev
    libgtk-4-dev libadwaita-1-dev
    xvfb xauth dbus dbus-x11 adwaita-icon-theme
    appstream desktop-file-utils librsvg2-bin gtk-update-icon-cache dpkg-dev rpm python3
)

if [[ "$APT" == 1 ]]; then
    note "Installing packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q --no-install-recommends "${APT_PACKAGES[@]}"
fi

. /etc/os-release
note "Distribution: $PRETTY_NAME; GTK $(pkg-config --modversion gtk4); libadwaita $(pkg-config --modversion libadwaita-1)"

arch=$(uname -m)
case "$arch" in
    x86_64) swift_suffix=ubuntu24.04; deb_arch=amd64 ;;
    aarch64) swift_suffix=ubuntu24.04-aarch64; deb_arch=arm64 ;;
    *) echo "ERROR: unsupported architecture $arch" >&2; exit 1 ;;
esac

# libxml2.so.2 for SwiftPM, lld and lldb (and FoundationXML, which the app
# does not use), when the system has none.
if ! ldconfig -p | grep -q 'libxml2\.so\.2 '; then
    note "Supplying libxml2.so.2 from the Ubuntu 24.04 packages..."
    compat=/opt/swift-compat
    mkdir -p "$compat"
    for name in "libxml2_$deb_arch" "libicu74_$deb_arch"; do
        deb=$(fetch_tool "$name")
        extract=$(mktemp -d)
        dpkg-deb -x "$deb" "$extract"
        cp -a "$extract"/usr/lib/*-linux-gnu/lib*.so.* "$compat/"
        rm -rf "$extract"
    done
    echo "$compat" >/etc/ld.so.conf.d/zz-swift-compat.conf
    ldconfig
    ldconfig -p | grep -q 'libxml2\.so\.2 ' || { echo "ERROR: libxml2.so.2 is still missing" >&2; exit 1; }
fi

name="swift-$LINUX_SWIFT_VERSION-RELEASE-$swift_suffix"
if [[ ! -x "$TOOLCHAIN_ROOT/$name/usr/bin/swift" ]]; then
    tarball=${ART_SWIFT_TARBALL:-}
    if [[ -n "$tarball" ]]; then
        verify_tool "swift_$arch" "$tarball"
    else
        note "Downloading $name..."
        tarball=$(fetch_tool "swift_$arch")
    fi
    mkdir -p "$TOOLCHAIN_ROOT"
    tar -xzf "$tarball" -C "$TOOLCHAIN_ROOT"
fi
bin="$TOOLCHAIN_ROOT/$name/usr/bin"
"$bin/swift" --version
if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "$bin" >>"$GITHUB_PATH"
fi
note "Swift is in $bin"
