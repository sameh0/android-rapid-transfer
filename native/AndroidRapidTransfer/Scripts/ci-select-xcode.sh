#!/usr/bin/env bash

# Picks the Xcode a CI run builds with and exports it as DEVELOPER_DIR.
#
#   Scripts/ci-select-xcode.sh [latest | latest-prerelease | <version prefix>]
#
#   latest             the newest release Xcode in /Applications (the default);
#                      the newest prerelease only if no release Xcode exists
#   latest-prerelease  the newest Xcode, betas included
#   26.6, 27, ...      the newest Xcode whose version starts with that prefix
#
# Fails, before anything is built, if that Xcode's Swift is older than the
# packages' swift-tools-version (or ART_MIN_SWIFT_VERSION, when set higher).
# On GitHub Actions it appends DEVELOPER_DIR to $GITHUB_ENV and writes the
# `version`, `build` and `swift` outputs (the SwiftPM cache is keyed on
# `build`). Nothing needs sudo: DEVELOPER_DIR overrides xcode-select.
#
# XCODE_SEARCH_DIR (default /Applications) is where Xcode bundles are looked for.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
NATIVE_DIR=$(cd "$PROJECT_DIR/.." && pwd)
REQUEST=${1:-latest}
SEARCH_DIR=${XCODE_SEARCH_DIR:-/Applications}

fail() {
    echo "ERROR: $*" >&2
    [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::error title=Xcode selection::$*"
    exit 1
}

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [latest | latest-prerelease | <version prefix>]" >&2
    exit 2
fi

# "1.2.3" >= "1.2"? Missing components count as 0.
version_at_least() {
    local IFS=.
    local -a have=($1) need=($2)
    local index a b
    for ((index = 0; index < ${#have[@]} || index < ${#need[@]}; index++)); do
        a=${have[index]:-0}
        b=${need[index]:-0}
        ((10#$a > 10#$b)) && return 0
        ((10#$a < 10#$b)) && return 1
    done
    return 0
}

# Every distinct Xcode bundle (runner images add version-named symlinks).
candidates=()
seen=" "
shopt -s nullglob
for app in "$SEARCH_DIR"/Xcode*.app; do
    real=$(cd "$app" 2>/dev/null && pwd -P) || continue
    [[ "$seen" == *" $real "* ]] && continue
    [[ -f "$real/Contents/version.plist" && -d "$real/Contents/Developer" ]] || continue
    seen+="$real "
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$real/Contents/version.plist" 2>/dev/null) || continue
    [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
    prerelease=0
    shopt -s nocasematch
    [[ "$(basename "$real")" =~ (beta|release.?candidate|_rc) ]] && prerelease=1
    shopt -u nocasematch
    candidates+=("$version|$prerelease|$real")
done
shopt -u nullglob

[[ ${#candidates[@]} -gt 0 ]] || fail "No Xcode found in $SEARCH_DIR."

echo "Xcode bundles found:"
printf '  %s\n' "${candidates[@]//|/  }"

pick() {
    # $1: allow prereleases (0/1), $2: version prefix or empty.
    local allow=$1 prefix=$2 best="" best_version="" entry version prerelease
    for entry in "${candidates[@]}"; do
        IFS='|' read -r version prerelease _ <<<"$entry"
        [[ "$allow" == 1 || "$prerelease" == 0 ]] || continue
        if [[ -n "$prefix" && "$version" != "$prefix" && "$version" != "$prefix".* ]]; then
            continue
        fi
        if [[ -z "$best" ]] || ! version_at_least "$best_version" "$version"; then
            best=$entry
            best_version=$version
        elif [[ "$version" == "$best_version" && "$prerelease" == 0 ]]; then
            best=$entry  # Same version: the release beats a prerelease.
        fi
    done
    echo "$best"
}

case "$REQUEST" in
    latest)
        selected=$(pick 0 "")
        [[ -n "$selected" ]] || selected=$(pick 1 "")
        ;;
    latest-prerelease) selected=$(pick 1 "") ;;
    *)
        [[ "$REQUEST" =~ ^[0-9]+(\.[0-9]+)*$ ]] \
            || fail "XCODE_VERSION must be latest, latest-prerelease or a version such as 26.6; got '$REQUEST'."
        selected=$(pick 0 "$REQUEST")
        [[ -n "$selected" ]] || selected=$(pick 1 "$REQUEST")
        ;;
esac
[[ -n "$selected" ]] || fail "No Xcode in $SEARCH_DIR matches '$REQUEST'."

IFS='|' read -r XCODE_VERSION _ XCODE_APP <<<"$selected"
export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
XCODE_BUILD=$(/usr/bin/xcrun xcodebuild -version | /usr/bin/awk '/^Build version/ { print $3 }') \
    || fail "xcodebuild in $XCODE_APP does not run."
[[ -n "$XCODE_BUILD" ]] || fail "Could not read the build version of $XCODE_APP."
SWIFT_VERSION=$(/usr/bin/xcrun swift --version 2>&1 \
    | /usr/bin/sed -nE 's/.*Apple Swift version ([0-9]+(\.[0-9]+)*).*/\1/p' | /usr/bin/head -n 1)
[[ -n "$SWIFT_VERSION" ]] || fail "Could not read the Swift version of $XCODE_APP."

# The packages' swift-tools-version is the floor; ART_MIN_SWIFT_VERSION can raise it.
MIN_SWIFT=0
for manifest in "$NATIVE_DIR"/*/Package.swift; do
    tools=$(/usr/bin/sed -nE '1s#^// swift-tools-version: *([0-9.]+).*#\1#p' "$manifest")
    [[ -n "$tools" ]] || continue
    version_at_least "$MIN_SWIFT" "$tools" || MIN_SWIFT=$tools
done
if [[ -n "${ART_MIN_SWIFT_VERSION:-}" ]] && ! version_at_least "$MIN_SWIFT" "$ART_MIN_SWIFT_VERSION"; then
    MIN_SWIFT=$ART_MIN_SWIFT_VERSION
fi

echo "Selected: Xcode $XCODE_VERSION ($XCODE_BUILD) at $XCODE_APP, Swift $SWIFT_VERSION"
version_at_least "$SWIFT_VERSION" "$MIN_SWIFT" \
    || fail "Xcode $XCODE_VERSION has Swift $SWIFT_VERSION, but the packages need Swift $MIN_SWIFT or later. Choose a newer Xcode (XCODE_VERSION) or runner image."
echo "Swift $SWIFT_VERSION satisfies the required $MIN_SWIFT."

if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "DEVELOPER_DIR=$DEVELOPER_DIR" >>"$GITHUB_ENV"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "version=$XCODE_VERSION"
        echo "build=$XCODE_BUILD"
        echo "swift=$SWIFT_VERSION"
        echo "developer-dir=$DEVELOPER_DIR"
    } >>"$GITHUB_OUTPUT"
fi
echo "DEVELOPER_DIR=$DEVELOPER_DIR"
