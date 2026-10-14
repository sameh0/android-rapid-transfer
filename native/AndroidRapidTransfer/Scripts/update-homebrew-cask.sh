#!/usr/bin/env bash

# Points the Homebrew cask at a release: sets its version and the sha256 of
# that release's DMG.
#
#   Scripts/update-homebrew-cask.sh <tap-dir> <version> <dmg>
#
# <tap-dir> is a checkout of HOMEBREW_TAP_REPOSITORY (release-config.sh) and
# <dmg> the release's own <artifact>-<version>.dmg, as downloaded from the
# published GitHub release. The cask only follows stable releases, so a
# prerelease version (1.2.3-beta.1) or one older than the cask's is refused.
# Prints "updated" or "unchanged"; commits nothing. .github/workflows/
# homebrew.yml runs it for every published release.

set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <tap-dir> <version> <dmg>" >&2
    exit 2
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=release-config.sh
source "$SCRIPT_DIR/release-config.sh"

tap_dir=$1
version=$2
dmg=$3
cask="$tap_dir/$HOMEBREW_CASK_PATH"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    fail "$version is not a stable release version (1.2.3); the cask skips prereleases."
[[ -f "$cask" ]] || fail "no cask at $cask."
[[ -f "$dmg" ]] || fail "no DMG at $dmg."
[[ "$(basename "$dmg")" == "$APP_ARTIFACT_NAME-$version.dmg" ]] ||
    fail "$(basename "$dmg") is not $APP_ARTIFACT_NAME-$version.dmg."

# The cask's url is built from #{version}, so these two lines are all that
# changes between releases. Each must appear exactly once.
version_line='^  version "[^"]*"$'
sha_line='^  sha256 "[^"]*"$'
[[ "$(grep -c "$version_line" "$cask")" -eq 1 ]] || fail "$cask has no single version line."
[[ "$(grep -c "$sha_line" "$cask")" -eq 1 ]] || fail "$cask has no single sha256 line."

current=$(sed -n 's/^  version "\(.*\)"$/\1/p' "$cask")
if [[ "$current" != "$version" &&
    "$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -n 1)" != "$version" ]]; then
    fail "the cask is at $current; refusing to move it back to $version."
fi

sha256=$(shasum -a 256 "$dmg" | awk '{ print $1 }')
[[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || fail "could not hash $dmg."

updated=$(mktemp)
trap 'rm -f "$updated"' EXIT
sed -e "s/$version_line/  version \"$version\"/" \
    -e "s/$sha_line/  sha256 \"$sha256\"/" "$cask" >"$updated"

if cmp -s "$cask" "$updated"; then
    echo "unchanged"
else
    cat "$updated" >"$cask"
    echo "updated"
fi
