#!/usr/bin/env bash

# Installs (or removes) the Linux app under a prefix, without a package manager.
#
#   linux-install.sh [--prefix DIR] [--from DIR] [--udev-rule]
#   linux-install.sh --uninstall [--prefix DIR] [--udev-rule]
#
#   --prefix     where to install (default ~/.local): bin/, share/applications,
#                share/metainfo and share/icons/hicolor under it
#   --from       the tree to install from, laid out like a prefix (bin/, share/,
#                lib/). Default: the directory this script is in when it holds
#                bin/android-rapid-transfer (an unpacked release tarball);
#                otherwise the tree Scripts/linux-build.sh staged, which is
#                built first if missing
#   --udev-rule  also install (or remove) the optional udev rule in
#                /etc/udev/rules.d and reload udev; needs root
#   --uninstall  remove what an earlier install put under the prefix
#
# The files installed are listed in <prefix>/share/android-rapid-transfer/
# installed-files, which --uninstall reads. Afterwards the desktop database and
# icon cache are refreshed when their tools are installed.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=linux-release-config.sh
source "$SCRIPT_DIR/linux-release-config.sh"

PREFIX="$HOME/.local"
FROM=""
UNINSTALL=0
UDEV=0

usage() {
    sed -n '/^#   linux-install.sh/,/^#   --uninstall/p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) PREFIX=${2:?}; shift ;;
        --from) FROM=${2:?}; shift ;;
        --uninstall) UNINSTALL=1 ;;
        --udev-rule) UDEV=1 ;;
        -h | --help) usage ;;
        *) echo "Unknown option $1" >&2; usage ;;
    esac
    shift
done

note() { echo "==> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

mkdir -p "$PREFIX"
PREFIX=$(cd "$PREFIX" && pwd)
MANIFEST="$PREFIX/share/$LINUX_PACKAGE_NAME/installed-files"
UDEV_NAME="70-$LINUX_PACKAGE_NAME.rules"
UDEV_TARGET="/etc/udev/rules.d/$UDEV_NAME"

refresh_caches() {
    local applications="$PREFIX/share/applications" icons="$PREFIX/share/icons/hicolor"
    if [[ -d "$applications" ]] && command -v update-desktop-database >/dev/null; then
        update-desktop-database -q "$applications" || true
    fi
    if [[ -d "$icons" ]]; then
        # Refresh an existing cache (a stale one hides new icons); where there
        # is none, GTK scans the directories, noticing the new modification time.
        touch "$icons"
        if [[ -f "$icons/icon-theme.cache" || -f "$icons/index.theme" ]]; then
            local tool
            for tool in gtk4-update-icon-cache gtk-update-icon-cache; do
                if command -v "$tool" >/dev/null; then
                    "$tool" -q -t -f "$icons" || true
                    break
                fi
            done
        fi
    fi
}

reload_udev() {
    if command -v udevadm >/dev/null; then
        udevadm control --reload || true
        udevadm trigger --subsystem-match=usb --action=change || true
    fi
}

# --- uninstall ------------------------------------------------------------------

if [[ "$UNINSTALL" == 1 ]]; then
    note "Removing $LINUX_APP_NAME from $PREFIX..."
    if [[ -f "$MANIFEST" ]]; then
        while IFS= read -r relative; do
            [[ -n "$relative" ]] || continue
            rm -f "$PREFIX/$relative"
            echo "    removed $PREFIX/$relative"
        done <"$MANIFEST"
        rm -f "$MANIFEST"
        rmdir "$(dirname "$MANIFEST")" 2>/dev/null || true
    else
        # No record (an install by an older script or by hand): remove the
        # files the app's install would have created.
        echo "    (no $MANIFEST; removing the app's known files)"
        rm -fv "$PREFIX/bin/$LINUX_EXECUTABLE" \
            "$PREFIX/share/applications/$LINUX_APP_ID.desktop" \
            "$PREFIX/share/metainfo/$LINUX_APP_ID.metainfo.xml" \
            "$PREFIX"/share/icons/hicolor/*/apps/"$LINUX_APP_ID".* \
            "$PREFIX/share/doc/$LINUX_PACKAGE_NAME/LICENSE" \
            "$PREFIX/share/doc/$LINUX_PACKAGE_NAME/README" | sed 's/^/    /'
    fi
    rmdir "$PREFIX/share/doc/$LINUX_PACKAGE_NAME" 2>/dev/null || true
    if [[ "$UDEV" == 1 && -f "$UDEV_TARGET" ]]; then
        rm -f "$UDEV_TARGET" || fail "Could not remove $UDEV_TARGET (run as root)"
        echo "    removed $UDEV_TARGET"
        reload_udev
    fi
    refresh_caches
    note "Uninstalled."
    exit 0
fi

# --- install --------------------------------------------------------------------

if [[ -z "$FROM" ]]; then
    if [[ -x "$SCRIPT_DIR/bin/$LINUX_EXECUTABLE" ]]; then
        FROM=$SCRIPT_DIR
    else
        PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
        FROM="$PROJECT_DIR/dist/stage/usr"
        if [[ ! -x "$FROM/bin/$LINUX_EXECUTABLE" ]]; then
            note "No staged build; running Scripts/linux-build.sh..."
            "$SCRIPT_DIR/linux-build.sh"
        fi
    fi
fi
[[ -x "$FROM/bin/$LINUX_EXECUTABLE" ]] || fail "$FROM has no bin/$LINUX_EXECUTABLE"
FROM=$(cd "$FROM" && pwd)

note "Installing $LINUX_APP_NAME into $PREFIX (from $FROM)..."
installed=()
put() { # put <mode> <relative path in FROM> [<relative path in PREFIX>]
    local mode=$1 source=$2 target=${3:-$2}
    install -Dm"$mode" "$FROM/$source" "$PREFIX/$target"
    installed+=("$target")
    echo "    $PREFIX/$target"
}

put 755 "bin/$LINUX_EXECUTABLE"
put 644 "share/metainfo/$LINUX_APP_ID.metainfo.xml"
while IFS= read -r icon; do
    put 644 "share/icons/hicolor/$icon"
done < <(cd "$FROM/share/icons/hicolor" && find . -type f -name "$LINUX_APP_ID.*" | sed 's|^\./||' | sort)
for doc in LICENSE README; do
    if [[ -f "$FROM/share/doc/$LINUX_PACKAGE_NAME/$doc" ]]; then
        put 644 "share/doc/$LINUX_PACKAGE_NAME/$doc"
    fi
done

# The desktop entry runs the command by name, which works for /usr and
# /usr/local. Elsewhere bin/ may not be on the session's PATH, so point it at
# the installed binary.
desktop_target="share/applications/$LINUX_APP_ID.desktop"
case "$PREFIX" in
    /usr | /usr/local) put 644 "$desktop_target" ;;
    *)
        install -d "$PREFIX/share/applications"
        sed -e "s|^Exec=$LINUX_EXECUTABLE|Exec=$PREFIX/bin/$LINUX_EXECUTABLE|" \
            -e "s|^TryExec=$LINUX_EXECUTABLE|TryExec=$PREFIX/bin/$LINUX_EXECUTABLE|" \
            "$FROM/$desktop_target" >"$PREFIX/$desktop_target"
        chmod 644 "$PREFIX/$desktop_target"
        installed+=("$desktop_target")
        echo "    $PREFIX/$desktop_target"
        ;;
esac

mkdir -p "$(dirname "$MANIFEST")"
printf '%s\n' "${installed[@]}" >"$MANIFEST"

udev_source="$FROM/lib/udev/rules.d/$UDEV_NAME"
if [[ "$UDEV" == 1 ]]; then
    [[ -f "$udev_source" ]] || fail "$FROM has no lib/udev/rules.d/$UDEV_NAME"
    install -Dm644 "$udev_source" "$UDEV_TARGET" || fail "Could not write $UDEV_TARGET (run as root, or without --udev-rule)"
    echo "    $UDEV_TARGET"
    reload_udev
fi

refresh_caches

note "Installed. Start it from the app launcher, or run $PREFIX/bin/$LINUX_EXECUTABLE"
case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) echo "    ($PREFIX/bin is not on your PATH.)" ;;
esac
if [[ "$UDEV" == 0 ]]; then
    echo "    If the app cannot open your phone (older phones on some distributions), install"
    echo "    the optional udev rule: sudo $0 --udev-rule --prefix $PREFIX"
fi
