#!/usr/bin/env bash

# The one entry point CI calls; every mode runs the same way on a Mac.
#
#   Scripts/ci-build.sh test
#       Builds and tests native/MTPKit, native/ARTCore, then
#       native/AndroidRapidTransfer, with compiler warnings treated as errors
#       (ART_WARNINGS_AS_ERRORS=0 turns that off). Logs land in <output>/logs.
#
#   Scripts/ci-build.sh package
#       Scripts/package-release.sh, then either Scripts/notarize.sh (Developer
#       ID signing, notarization and stapling, when the credentials below are
#       all present) or Scripts/make-dmg.sh (ad-hoc signed). The DMG is mounted
#       and checked, then copied to <output> with SHA256SUMS and build-info.txt.
#
#   Scripts/ci-build.sh appcast <release-tag>
#       Scripts/make-appcast.sh for a Developer ID build that `package` made,
#       signed with SPARKLE_ED_PRIVATE_KEY; adds appcast.xml to <output>.
#       Skipped (successfully) without the key or for an ad-hoc build.
#
#   Scripts/ci-build.sh verify [<dmg>]
#       Only the DMG checks `package` runs (default: the DMG in <output>).
#
# <output> is ART_CI_OUTPUT_DIR, default native/AndroidRapidTransfer/ci-artifacts.
#
# Signing (package). The DMG is ad-hoc signed, and named *-adhoc.dmg, unless
# DEVELOPER_ID_APP names a codesigning identity in the keychain search list and
# notarization credentials are complete: either APPLE_ID, TEAM_ID and
# APP_PASSWORD, or NOTARY_API_KEY_PATH, NOTARY_API_KEY_ID and
# NOTARY_API_ISSUER_ID (Scripts/notarize.sh reads the same variables).
#   ART_SIGNING=auto|adhoc   adhoc ignores any credentials (default auto)
#   ART_REQUIRE_SIGNING=1    fail instead of falling back to ad-hoc
#   ART_RELEASE_TAG=v1.2.3   fail unless the tag is v<AppVersion.current>
#   BUILD_NUMBER             CFBundleVersion (see resolve_build_number)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
NATIVE_DIR=$(cd "$PROJECT_DIR/.." && pwd)
REPO_ROOT=$(cd "$NATIVE_DIR/.." && pwd)
RELEASE_DIR="$PROJECT_DIR/release"
APP_VERSION_FILE="$PROJECT_DIR/../ARTCore/Sources/AndroidRapidTransferCore/AppVersion.swift"
OUTPUT_DIR=${ART_CI_OUTPUT_DIR:-$PROJECT_DIR/ci-artifacts}
LOG_DIR="$OUTPUT_DIR/logs"
BUILD_INFO="$OUTPUT_DIR/build-info.txt"
# shellcheck source=release-config.sh
source "$SCRIPT_DIR/release-config.sh"

usage() {
    echo "Usage: $0 test | package | appcast <release-tag> | verify [<dmg>]" >&2
    exit 2
}

note() { echo "==> $*"; }

fail() {
    echo "ERROR: $*" >&2
    [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::error title=ci-build::$*"
    exit 1
}

warn() {
    echo "WARNING: $*" >&2
    [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::warning title=ci-build::$*"
    return 0
}

set_output() {
    [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "$1=$2" >>"$GITHUB_OUTPUT"
    return 0
}

app_version() {
    local version
    version=$(sed -nE 's/^[[:space:]]*public static let current = "([^"]+)"/\1/p' "$APP_VERSION_FILE")
    [[ -n "$version" ]] || fail "Could not read AppVersion.current from $APP_VERSION_FILE"
    echo "$version"
}

# Everything below runs with the Xcode DEVELOPER_DIR names (or xcode-select's).
toolchain_summary() {
    local xcode swift sdk
    xcode=$(/usr/bin/xcrun xcodebuild -version 2>/dev/null | /usr/bin/paste -sd ' ' -) || xcode="unknown"
    swift=$(/usr/bin/xcrun swift --version 2>&1 | /usr/bin/head -n 1) || swift="unknown"
    sdk=$(/usr/bin/xcrun --sdk macosx --show-sdk-version 2>/dev/null) || sdk="unknown"
    XCODE_SUMMARY=$xcode
    SWIFT_SUMMARY=$swift
    SDK_VERSION=$sdk
}

require_xcode() {
    local developer_dir
    developer_dir=$(/usr/bin/xcode-select -p 2>/dev/null || true)
    developer_dir=${DEVELOPER_DIR:-$developer_dir}
    if [[ "$developer_dir" == *CommandLineTools* || -z "$developer_dir" ]]; then
        fail "The Command Line Tools cannot build SwiftUI macros; export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer (CI: Scripts/ci-select-xcode.sh)."
    fi
    toolchain_summary
    note "Toolchain: $XCODE_SUMMARY; $SWIFT_SUMMARY; macOS SDK $SDK_VERSION"
}

# Runs "$@", teeing its output into $1-named log. Usage: logged <log> <cmd...>
logged() {
    local log=$1
    shift
    echo "\$ $*" >"$log"
    "$@" 2>&1 | /usr/bin/tee -a "$log"
}

# --- test ---------------------------------------------------------------------

run_tests() {
    [[ $# -eq 0 ]] || usage
    require_xcode
    /bin/mkdir -p "$LOG_DIR"
    local flags=()
    if [[ "${ART_WARNINGS_AS_ERRORS:-1}" == 1 ]]; then
        flags=(-Xswiftc -warnings-as-errors)
        note "Compiler warnings are errors (ART_WARNINGS_AS_ERRORS=0 to allow them)."
    fi
    local package summary=()
    for package in MTPKit ARTCore AndroidRapidTransfer; do
        note "Building $package and its tests..."
        (cd "$NATIVE_DIR/$package" \
            && logged "$LOG_DIR/$package-build.log" swift build --build-tests ${flags[@]+"${flags[@]}"}) \
            || fail "$package failed to build; see $LOG_DIR/$package-build.log"
        note "Testing $package..."
        (cd "$NATIVE_DIR/$package" \
            && logged "$LOG_DIR/$package-test.log" swift test --skip-build ${flags[@]+"${flags[@]}"}) \
            || fail "$package tests failed; see $LOG_DIR/$package-test.log"
        # A crash can end a run early; count only runs in which every XCTest
        # bundle (SwiftPM may run each separately) reached its final summary.
        local totals
        totals=$(/usr/bin/awk '
            /^Test Suite .All tests. started/ { started++ }
            /^Test Suite .All tests. passed/ { passed++; summary = 1; next }
            /^Test Suite .All tests. failed/ { failed++ }
            summary && /Executed [0-9]+ test/ {
                for (i = 1; i <= NF; i++) {
                    if ($i == "Executed") executed += $(i + 1)
                    if ($i == "skipped" && $(i - 1) ~ /^tests?$/) skipped += $(i - 2)
                }
                summary = 0
            }
            END { printf "%d %d %d %d %d\n", started, passed, failed, executed, skipped }
        ' "$LOG_DIR/$package-test.log")
        local started passed failed executed skipped
        read -r started passed failed executed skipped <<<"$totals"
        [[ "$started" -gt 0 && "$passed" -eq "$started" && "$failed" -eq 0 ]] \
            || fail "$package tests did not all report completion ($passed of $started XCTest runs passed); see $LOG_DIR/$package-test.log"
        summary+=("$package (XCTest): $executed tests, $skipped skipped, 0 failures in $started test bundle run(s)")
        local testing
        testing=$(/usr/bin/awk '/Test run with [0-9]+ tests?/ {
            for (i = 1; i <= NF; i++) if ($i == "with") total += $(i + 1)
        } END { print total + 0 }' "$LOG_DIR/$package-test.log")
        [[ "$testing" -eq 0 ]] || summary+=("$package (Swift Testing): $testing tests passed")
    done
    note "Test summary:"
    printf '    %s\n' "${summary[@]}"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        {
            echo "### Tests"
            echo
            echo "$XCODE_SUMMARY; $SWIFT_SUMMARY"
            echo
            printf -- '- %s\n' "${summary[@]}"
        } >>"$GITHUB_STEP_SUMMARY"
    fi
}

# --- verify -------------------------------------------------------------------

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

expect_equal() {
    local what=$1 actual=$2 expected=$3
    [[ "$actual" == "$expected" ]] || fail "$what is '$actual', expected '$expected'"
    echo "    ok  $what = $actual"
}

verify_universal_binary() {
    local binary=$1 arches
    arches=$(/usr/bin/xcrun lipo -archs "$binary")
    [[ " $arches " == *" arm64 "* && " $arches " == *" x86_64 "* && $(wc -w <<<"$arches") -eq 2 ]] \
        || fail "$binary is not universal (architectures: $arches)"
    echo "    ok  universal ($arches): ${binary#"$MOUNT_POINT/"}"
}

# Mounts the DMG and checks the app in it. Usage: verify_dmg <dmg> <signing>
# where <signing> is adhoc or developer-id; <build> defaults to BUILD_NUMBER.
verify_dmg() {
    local dmg=$1 signing=$2
    [[ -f "$dmg" ]] || fail "Missing $dmg"
    MOUNT_POINT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/art-ci-verify.XXXXXX")
    /usr/bin/hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$MOUNT_POINT" -quiet \
        || fail "Could not mount $dmg"
    # shellcheck disable=SC2064
    trap "/usr/bin/hdiutil detach '$MOUNT_POINT' -quiet || true; /bin/rmdir '$MOUNT_POINT' 2>/dev/null || true" EXIT

    local app="$MOUNT_POINT/$APP_DISPLAY_NAME.app"
    local contents="$app/Contents" plist="$app/Contents/Info.plist"
    note "Verifying $(basename "$dmg") ($signing)..."
    [[ -d "$app" ]] || fail "The DMG has no $APP_DISPLAY_NAME.app"
    [[ -L "$MOUNT_POINT/Applications" ]] || fail "The DMG has no Applications symlink"
    verify_bundle_layout "$app" || fail "The app in the DMG failed the layout check"

    verify_universal_binary "$contents/MacOS/$APP_EXECUTABLE"
    verify_universal_binary "$contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"

    /usr/bin/plutil -lint "$plist" >/dev/null || fail "Info.plist does not lint"
    expect_equal CFBundleIdentifier "$(plist_value "$plist" CFBundleIdentifier)" "$APP_BUNDLE_ID"
    expect_equal CFBundleExecutable "$(plist_value "$plist" CFBundleExecutable)" "$APP_EXECUTABLE"
    expect_equal CFBundleShortVersionString "$(plist_value "$plist" CFBundleShortVersionString)" "$APP_VERSION"
    expect_equal CFBundleVersion "$(plist_value "$plist" CFBundleVersion)" "$BUILD_NUMBER"
    expect_equal LSMinimumSystemVersion "$(plist_value "$plist" LSMinimumSystemVersion)" "14.0"
    expect_equal SUFeedURL "$(plist_value "$plist" SUFeedURL)" "$SPARKLE_FEED_URL"
    expect_equal SUPublicEDKey "$(plist_value "$plist" SUPublicEDKey)" "$SPARKLE_PUBLIC_ED_KEY"
    expect_equal "UTExportedTypeDeclarations[0]" \
        "$(plist_value "$plist" UTExportedTypeDeclarations:0:UTTypeIdentifier)" "$APP_BUNDLE_ID.local-items"
    expect_equal "UTExportedTypeDeclarations[1]" \
        "$(plist_value "$plist" UTExportedTypeDeclarations:1:UTTypeIdentifier)" "$APP_BUNDLE_ID.device-items"
    expect_equal CFBundleIconFile "$(plist_value "$plist" CFBundleIconFile)" "$APP_ICON_NAME"
    /usr/bin/cmp -s "$contents/Resources/$APP_ICON_NAME.icns" "$PROJECT_DIR/Resources/$APP_ICON_NAME.icns" \
        || fail "Contents/Resources/$APP_ICON_NAME.icns is missing or differs from Resources/"
    echo "    ok  icon: Contents/Resources/$APP_ICON_NAME.icns"
    [[ -s "$contents/Resources/Acknowledgements.txt" ]] || fail "Acknowledgements.txt is missing"
    echo "    ok  Contents/Resources/Acknowledgements.txt"

    # pipefail: a codesign failure fails the pipeline.
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$app" 2>&1 | /usr/bin/sed 's/^/    /' \
        || fail "codesign --verify --deep --strict failed"
    local details
    details=$(/usr/bin/codesign --display --verbose=2 "$app" 2>&1)
    [[ "$details" =~ flags=0x[0-9a-f]+\([^\)]*runtime ]] \
        || fail "The app is not signed with the hardened runtime"
    echo "    ok  hardened runtime"
    case "$signing" in
        adhoc)
            [[ "$details" == *"Signature=adhoc"* ]] || fail "Expected an ad-hoc signature"
            echo "    ok  ad-hoc signature (not Developer ID, not notarized)"
            ;;
        developer-id)
            [[ "$details" == *"Authority=Developer ID Application:"* ]] \
                || fail "Expected a Developer ID Application signature"
            echo "    ok  $(/usr/bin/grep -m1 '^Authority=Developer ID Application' <<<"$details")"
            /usr/bin/xcrun stapler validate "$dmg" || fail "The DMG has no valid stapled ticket"
            /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg" \
                || fail "Gatekeeper rejects the DMG"
            /usr/sbin/spctl --assess --type execute --verbose=2 "$app" \
                || fail "Gatekeeper rejects the app"
            echo "    ok  notarized, stapled and accepted by Gatekeeper"
            ;;
        *) fail "Unknown signing mode '$signing'" ;;
    esac

    /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet
    /bin/rmdir "$MOUNT_POINT" 2>/dev/null || true
    trap - EXIT
    note "DMG verified."
}

read_build_info() {
    [[ -f "$BUILD_INFO" ]] || fail "Missing $BUILD_INFO; run '$0 package' first."
    # Values are simple KEY=value lines written by write_build_info.
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            ''|'#'*) ;;
            *) printf -v "INFO_$key" '%s' "$value" ;;
        esac
    done <"$BUILD_INFO"
}

run_verify() {
    [[ $# -le 1 ]] || usage
    APP_VERSION=$(app_version)
    read_build_info
    BUILD_NUMBER=$INFO_BUILD_NUMBER
    verify_dmg "${1:-$OUTPUT_DIR/$INFO_DMG}" "$INFO_SIGNING"
}

# --- package ------------------------------------------------------------------

decide_signing() {
    local requested=${ART_SIGNING:-auto} missing=()
    SIGNING=adhoc
    NOTARY_METHOD=none
    case "$requested" in
        adhoc) note "Signing: ad-hoc (ART_SIGNING=adhoc)." ;;
        auto)
            if [[ -z "${DEVELOPER_ID_APP:-}" ]]; then
                note "Signing: ad-hoc. Developer ID signing and notarization are skipped: no DEVELOPER_ID_APP. In CI, add the secrets DEVELOPER_ID_P12_BASE64 and DEVELOPER_ID_P12_PASSWORD, plus APPLE_ID, TEAM_ID and APP_PASSWORD (or NOTARY_API_KEY_P8_BASE64, NOTARY_API_KEY_ID and NOTARY_API_ISSUER_ID), to enable them."
            elif [[ -n "${NOTARY_API_KEY_PATH:-}" && -n "${NOTARY_API_KEY_ID:-}" && -n "${NOTARY_API_ISSUER_ID:-}" ]]; then
                SIGNING=developer-id
                NOTARY_METHOD=api-key
            else
                local variable
                for variable in APPLE_ID TEAM_ID APP_PASSWORD; do
                    [[ -n "${!variable:-}" ]] || missing+=("$variable")
                done
                if [[ ${#missing[@]} -eq 0 ]]; then
                    SIGNING=developer-id
                    NOTARY_METHOD=apple-id
                else
                    warn "A Developer ID identity is available but notarization credentials are incomplete (missing ${missing[*]}, and no complete NOTARY_API_KEY_* set); building ad-hoc instead."
                fi
            fi
            ;;
        *) fail "ART_SIGNING must be auto or adhoc; got '$requested'" ;;
    esac
    if [[ "$SIGNING" == adhoc && "${ART_REQUIRE_SIGNING:-0}" == 1 ]]; then
        fail "ART_REQUIRE_SIGNING=1 but this build would be ad-hoc signed."
    fi
    [[ "$SIGNING" == developer-id ]] \
        && note "Signing: Developer ID '$DEVELOPER_ID_APP', notarized with $NOTARY_METHOD credentials."
    return 0
}

write_build_info() {
    local dmg_name=$1 sha=$2 git_sha git_ref dirty signing_label
    git_sha=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
    git_ref=${GITHUB_REF_NAME:-$(git -C "$REPO_ROOT" describe --tags --exact-match 2>/dev/null \
        || git -C "$REPO_ROOT" symbolic-ref --short -q HEAD 2>/dev/null || echo detached)}
    dirty=false
    [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]] && dirty=true
    if [[ "$SIGNING" == adhoc ]]; then
        signing_label="ad-hoc (unsigned: no Developer ID, not notarized; Gatekeeper will warn)"
    else
        signing_label="Developer ID ($DEVELOPER_ID_APP), notarized and stapled"
    fi
    {
        echo "# $APP_DISPLAY_NAME build information (KEY=value)"
        echo "APP_NAME=$APP_DISPLAY_NAME"
        echo "BUNDLE_ID=$APP_BUNDLE_ID"
        echo "VERSION=$APP_VERSION"
        echo "BUILD_NUMBER=$BUILD_NUMBER"
        echo "PRERELEASE=$([[ "$APP_VERSION" == *-* ]] && echo true || echo false)"
        echo "SIGNING=$SIGNING"
        echo "SIGNING_DESCRIPTION=$signing_label"
        echo "NOTARIZED=$([[ "$SIGNING" == developer-id ]] && echo true || echo false)"
        echo "ARCHITECTURES=arm64 x86_64"
        echo "MINIMUM_MACOS=14.0"
        echo "DMG=$dmg_name"
        echo "DMG_SHA256=$sha"
        echo "GIT_SHA=$git_sha"
        echo "GIT_REF=$git_ref"
        echo "GIT_DIRTY=$dirty"
        echo "XCODE=$XCODE_SUMMARY"
        echo "SWIFT=$SWIFT_SUMMARY"
        echo "MACOS_SDK=$SDK_VERSION"
        echo "BUILD_HOST_MACOS=$(/usr/bin/sw_vers -productVersion) ($(/usr/bin/sw_vers -buildVersion))"
        echo "BUILT_AT=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
        if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
            echo "CI_RUN=${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID"
        fi
    } >"$BUILD_INFO"
}

write_checksums() {
    (
        cd "$OUTPUT_DIR"
        local files=()
        local file
        for file in *.dmg appcast.xml; do
            [[ -f "$file" ]] && files+=("$file")
        done
        [[ ${#files[@]} -gt 0 ]] || fail "Nothing to checksum in $OUTPUT_DIR"
        /usr/bin/shasum -a 256 "${files[@]}" >SHA256SUMS
        /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null
    )
}

run_package() {
    [[ $# -eq 0 ]] || usage
    require_xcode
    APP_VERSION=$(app_version)
    if [[ -n "${ART_RELEASE_TAG:-}" && "$ART_RELEASE_TAG" != "v$APP_VERSION" ]]; then
        fail "Tag $ART_RELEASE_TAG does not match AppVersion.current ($APP_VERSION); expected v$APP_VERSION."
    fi
    BUILD_NUMBER=$(resolve_build_number "$REPO_ROOT") || fail "Invalid build number"
    export BUILD_NUMBER
    decide_signing

    local resolved_output
    resolved_output=$(/bin/mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd -P)
    case "$resolved_output" in
        / | "$(cd "$HOME" && pwd -P)" | "$(cd "$REPO_ROOT" && pwd -P)" | "$(cd "$NATIVE_DIR" && pwd -P)" | "$(cd "$PROJECT_DIR" && pwd -P)")
            fail "ART_CI_OUTPUT_DIR must be a dedicated directory (it is emptied); got $OUTPUT_DIR" ;;
    esac
    /bin/rm -rf "$OUTPUT_DIR"
    /bin/mkdir -p "$LOG_DIR"
    note "Packaging $APP_DISPLAY_NAME $APP_VERSION (build $BUILD_NUMBER)..."
    logged "$LOG_DIR/package-release.log" "$SCRIPT_DIR/package-release.sh" \
        || fail "package-release.sh failed; see $LOG_DIR/package-release.log"
    if [[ "$SIGNING" == developer-id ]]; then
        logged "$LOG_DIR/notarize.log" "$SCRIPT_DIR/notarize.sh" \
            || fail "notarize.sh failed; see $LOG_DIR/notarize.log"
    else
        logged "$LOG_DIR/make-dmg.log" "$SCRIPT_DIR/make-dmg.sh" \
            || fail "make-dmg.sh failed; see $LOG_DIR/make-dmg.log"
    fi

    local source_dmg="$RELEASE_DIR/$APP_ARTIFACT_NAME-$APP_VERSION.dmg" dmg_name
    [[ -f "$source_dmg" ]] || fail "The packaging scripts did not produce $source_dmg"
    if [[ "$SIGNING" == adhoc ]]; then
        dmg_name="$APP_ARTIFACT_NAME-$APP_VERSION-adhoc.dmg"
    else
        dmg_name="$APP_ARTIFACT_NAME-$APP_VERSION.dmg"
    fi
    /bin/cp "$source_dmg" "$OUTPUT_DIR/$dmg_name"
    verify_dmg "$OUTPUT_DIR/$dmg_name" "$SIGNING"
    write_checksums
    local sha
    sha=$(/usr/bin/awk -v name="$dmg_name" '$2 == name { print $1 }' "$OUTPUT_DIR/SHA256SUMS")
    write_build_info "$dmg_name" "$sha"

    local short_sha
    short_sha=$(git -C "$REPO_ROOT" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)
    set_output version "$APP_VERSION"
    set_output build-number "$BUILD_NUMBER"
    set_output signing "$SIGNING"
    set_output prerelease "$([[ "$APP_VERSION" == *-* ]] && echo true || echo false)"
    set_output dmg "$OUTPUT_DIR/$dmg_name"
    set_output output-dir "$OUTPUT_DIR"
    set_output artifact-name "$APP_ARTIFACT_NAME-$APP_VERSION-build$BUILD_NUMBER-$short_sha-$SIGNING"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        {
            echo "### $APP_DISPLAY_NAME $APP_VERSION (build $BUILD_NUMBER)"
            echo
            echo '```'
            /bin/cat "$BUILD_INFO"
            echo '```'
        } >>"$GITHUB_STEP_SUMMARY"
    fi

    note "Artifacts in $OUTPUT_DIR:"
    (cd "$OUTPUT_DIR" && /bin/ls -l)
    /bin/cat "$BUILD_INFO"
    echo "SUCCESS: $OUTPUT_DIR/$dmg_name ($SIGNING)"
}

# --- appcast ------------------------------------------------------------------

run_appcast() {
    [[ $# -eq 1 ]] || usage
    local tag=$1
    APP_VERSION=$(app_version)
    read_build_info
    [[ "$INFO_VERSION" == "$APP_VERSION" ]] \
        || fail "$BUILD_INFO is for $INFO_VERSION, but AppVersion.current is $APP_VERSION"
    if [[ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
        note "Sparkle appcast: skipped (no SPARKLE_ED_PRIVATE_KEY secret; export it with Sparkle's generate_keys -x)."
        return 0
    fi
    if [[ "$INFO_SIGNING" != developer-id ]]; then
        note "Sparkle appcast: skipped for an ad-hoc build; ad-hoc builds never enter the update feed. Add the Developer ID and notarization secrets to enable it."
        return 0
    fi
    [[ -f "$RELEASE_DIR/$INFO_DMG" ]] \
        || fail "Missing $RELEASE_DIR/$INFO_DMG; run '$0 package' in this checkout first."

    local channel=()
    [[ "$APP_VERSION" == *-* ]] && channel=(--beta)

    # make-appcast.sh hands SPARKLE_ED_PRIVATE_KEY to generate_appcast on stdin.
    export SPARKLE_ED_PRIVATE_KEY
    /bin/mkdir -p "$LOG_DIR"
    logged "$LOG_DIR/make-appcast.log" "$SCRIPT_DIR/make-appcast.sh" "$tag" ${channel[@]+"${channel[@]}"} \
        || fail "make-appcast.sh failed; see $LOG_DIR/make-appcast.log"

    /bin/cp "$RELEASE_DIR/appcast/appcast.xml" "$OUTPUT_DIR/appcast.xml"
    write_checksums
    set_output appcast "$OUTPUT_DIR/appcast.xml"
    echo "SUCCESS: $OUTPUT_DIR/appcast.xml (upload it to the latest non-prerelease release when publishing)"
}

MODE=${1:-}
[[ -n "$MODE" ]] || usage
shift
case "$MODE" in
    test) run_tests "$@" ;;
    package) run_package "$@" ;;
    appcast) run_appcast "$@" ;;
    verify) run_verify "$@" ;;
    *) usage ;;
esac
