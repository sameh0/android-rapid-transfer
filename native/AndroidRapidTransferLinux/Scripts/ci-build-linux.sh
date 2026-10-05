#!/usr/bin/env bash

# The one entry point Linux CI calls; every mode runs the same way on a Linux
# machine with Swift 6.3, GTK 4 and libadwaita (Scripts/linux-ci-setup.sh sets
# up an Ubuntu 26.04 container like the one CI uses).
#
#   Scripts/ci-build-linux.sh test
#       Checks the packaging metadata, then builds and tests native/MTPKit,
#       native/ARTCore and native/AndroidRapidTransferLinux with compiler
#       warnings treated as errors (ART_WARNINGS_AS_ERRORS=0 turns that off),
#       then runs the GTK self-tests (below) against a real display: Xvfb when
#       there is no display and xvfb-run is installed. Logs land in <output>/logs.
#
#   Scripts/ci-build-linux.sh package
#       Scripts/linux-build.sh, then Scripts/linux-package.sh all: the tarball,
#       AppImage, .deb and .rpm in <output>, with SHA256SUMS-linux-<arch> and
#       build-info-linux-<arch>.txt. The staged binary and the AppImage are
#       started once with the self-test arguments when the product has them.
#
# <output> is ART_CI_OUTPUT_DIR, default native/AndroidRapidTransferLinux/ci-artifacts.
#
# Environment:
#   ART_LINUX_PRODUCT      product to package (default: android-rapid-transfer
#                          when Package.swift declares it, else the art-gtk-demo
#                          stand-in, with a warning)
#   ART_LINUX_SELF_TESTS   products whose `--self-test` must print
#                          "VERIFICATION ok" (default: art-gtk-demo android-rapid-transfer)
#   ART_LINUX_SCRATCH_ROOT build directories go in <root>/<package> instead of
#                          each package's .build (for checkouts on slow disks)
#   ART_RELEASE_TAG=v1.2.3 fail unless the tag is v<AppVersion.current>

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
NATIVE_DIR=$(cd "$PROJECT_DIR/.." && pwd)
REPO_ROOT=$(cd "$NATIVE_DIR/.." && pwd)
APP_VERSION_FILE="$NATIVE_DIR/ARTCore/Sources/AndroidRapidTransferCore/AppVersion.swift"
OUTPUT_DIR=${ART_CI_OUTPUT_DIR:-$PROJECT_DIR/ci-artifacts}
# Absolute: the build steps run from inside each package directory.
[[ "$OUTPUT_DIR" == /* ]] || OUTPUT_DIR="$PWD/$OUTPUT_DIR"
LOG_DIR="$OUTPUT_DIR/logs"
SELF_TESTS=${ART_LINUX_SELF_TESTS:-art-gtk-demo android-rapid-transfer}
ARCH=$(uname -m)
# shellcheck source=linux-release-config.sh
source "$SCRIPT_DIR/linux-release-config.sh"

usage() {
    echo "Usage: $0 test | package" >&2
    exit 2
}

note() { echo "==> $*"; }

fail() {
    echo "ERROR: $*" >&2
    [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::error title=ci-build-linux::$*"
    exit 1
}

warn() {
    echo "WARNING: $*" >&2
    [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::warning title=ci-build-linux::$*"
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

scratch_args() { # scratch_args <package>
    if [[ -n "${ART_LINUX_SCRATCH_ROOT:-}" ]]; then
        echo "--scratch-path"
        echo "$ART_LINUX_SCRATCH_ROOT/$1"
    fi
}

toolchain_summary() {
    SWIFT_SUMMARY=$(swift --version 2>&1 | head -n 1)
    local distro
    distro=$(. /etc/os-release && echo "$PRETTY_NAME")
    SYSTEM_SUMMARY="$distro, $ARCH; GTK $(pkg-config --modversion gtk4 2>/dev/null || echo '?'); libadwaita $(pkg-config --modversion libadwaita-1 2>/dev/null || echo '?'); glibc $(ldd --version | head -n 1 | awk '{print $NF}')"
    note "Toolchain: $SWIFT_SUMMARY; $SYSTEM_SUMMARY"
}

# Runs "$@", teeing its output into the log named $1. Usage: logged <log> <cmd...>
logged() {
    local log=$1
    shift
    echo "\$ $*" >"$log"
    "$@" 2>&1 | tee -a "$log"
}

# Runs a GUI command against a display: the session's, or Xvfb's.
with_display() {
    if [[ -n "${WAYLAND_DISPLAY:-}" || -n "${DISPLAY:-}" || -n "${BROADWAY_DISPLAY:-}" ]]; then
        "$@"
    elif command -v xvfb-run >/dev/null; then
        if command -v dbus-run-session >/dev/null; then
            xvfb-run --auto-servernum -- dbus-run-session -- "$@"
        else
            xvfb-run --auto-servernum -- "$@"
        fi
    else
        fail "No display for the GTK self-test: set DISPLAY or install xvfb (xvfb-run)"
    fi
}

# A run counts only if it completes: exit 0 and the VERIFICATION marker.
# Usage: run_self_test <label> <log> <command...>
run_self_test() {
    local label=$1 log=$2 status=0
    shift 2
    note "Self-test: $label..."
    logged "$log" with_display timeout 300 "$@" --self-test || status=$?
    [[ "$status" -eq 0 ]] || fail "$label --self-test exited with status $status; see $log"
    grep -q '^VERIFICATION ok' "$log" || fail "$label --self-test did not report VERIFICATION ok; see $log"
    grep -m1 '^VERIFICATION' "$log" | sed 's/^/    /'
}

# --- test -----------------------------------------------------------------------

run_tests() {
    [[ $# -eq 0 ]] || usage
    toolchain_summary
    mkdir -p "$LOG_DIR"
    logged "$LOG_DIR/metadata.log" "$SCRIPT_DIR/linux-build.sh" --check-only \
        || fail "The packaging metadata check failed; see $LOG_DIR/metadata.log"
    local flags=()
    if [[ "${ART_WARNINGS_AS_ERRORS:-1}" == 1 ]]; then
        flags=(-Xswiftc -warnings-as-errors)
        note "Compiler warnings are errors (ART_WARNINGS_AS_ERRORS=0 to allow them)."
    fi
    local package summary=() scratch
    for package in MTPKit ARTCore AndroidRapidTransferLinux; do
        mapfile -t scratch < <(scratch_args "$package")
        note "Building $package and its tests..."
        (cd "$NATIVE_DIR/$package" \
            && logged "$LOG_DIR/$package-build.log" swift build --build-tests ${scratch[@]+"${scratch[@]}"} ${flags[@]+"${flags[@]}"}) \
            || fail "$package failed to build; see $LOG_DIR/$package-build.log"
        note "Testing $package..."
        (cd "$NATIVE_DIR/$package" \
            && logged "$LOG_DIR/$package-test.log" swift test --skip-build ${scratch[@]+"${scratch[@]}"} ${flags[@]+"${flags[@]}"}) \
            || fail "$package tests failed; see $LOG_DIR/$package-test.log"
        # A crash can end a run early; count only runs in which every XCTest
        # bundle reached its final summary.
        local totals started passed failed executed skipped
        totals=$(awk '
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
        read -r started passed failed executed skipped <<<"$totals"
        [[ "$started" -gt 0 && "$passed" -eq "$started" && "$failed" -eq 0 ]] \
            || fail "$package tests did not all report completion ($passed of $started XCTest runs passed); see $LOG_DIR/$package-test.log"
        summary+=("$package (XCTest): $executed tests, $skipped skipped, 0 failures in $started test bundle run(s)")
        local testing
        testing=$(awk '/Test run with [0-9]+ tests?/ {
            for (i = 1; i <= NF; i++) if ($i == "with") total += $(i + 1)
        } END { print total + 0 }' "$LOG_DIR/$package-test.log")
        [[ "$testing" -eq 0 ]] || summary+=("$package (Swift Testing): $testing tests passed")
    done

    local product bin_dir
    mapfile -t scratch < <(scratch_args AndroidRapidTransferLinux)
    bin_dir=$(cd "$PROJECT_DIR" && swift build --show-bin-path ${scratch[@]+"${scratch[@]}"})
    for product in $SELF_TESTS; do
        [[ -x "$bin_dir/$product" ]] || fail "No $bin_dir/$product to self-test"
        run_self_test "$product" "$LOG_DIR/$product-self-test.log" "$bin_dir/$product"
        summary+=("$product --self-test: $(grep -m1 '^VERIFICATION' "$LOG_DIR/$product-self-test.log")")
    done

    note "Test summary:"
    printf '    %s\n' "${summary[@]}"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        {
            echo "### Linux tests ($ARCH)"
            echo
            echo "$SWIFT_SUMMARY; $SYSTEM_SUMMARY"
            echo
            printf -- '- %s\n' "${summary[@]}"
        } >>"$GITHUB_STEP_SUMMARY"
    fi
}

# --- package --------------------------------------------------------------------

choose_product() {
    if [[ -n "${ART_LINUX_PRODUCT:-}" ]]; then
        PRODUCT=$ART_LINUX_PRODUCT
    elif grep -q "\.executable(name: \"$LINUX_PRODUCT\"" "$PROJECT_DIR/Package.swift"; then
        PRODUCT=$LINUX_PRODUCT
    else
        PRODUCT=art-gtk-demo
        warn "Package.swift has no $LINUX_PRODUCT product yet; packaging the art-gtk-demo stand-in."
    fi
}

write_build_info() {
    local info=$1 git_sha git_ref dirty file
    git_sha=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
    git_ref=${GITHUB_REF_NAME:-$(git -C "$REPO_ROOT" describe --tags --exact-match 2>/dev/null \
        || git -C "$REPO_ROOT" symbolic-ref --short -q HEAD 2>/dev/null || echo detached)}
    dirty=false
    [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]] && dirty=true
    {
        echo "# $LINUX_APP_NAME Linux build information (KEY=value)"
        echo "APP_NAME=$LINUX_APP_NAME"
        echo "APP_ID=$LINUX_APP_ID"
        echo "VERSION=$APP_VERSION"
        echo "PRERELEASE=$([[ "$APP_VERSION" == *-* ]] && echo true || echo false)"
        echo "PRODUCT=$PRODUCT"
        echo "ARCHITECTURE=$ARCH"
        echo "MINIMUM_GTK=$LINUX_MIN_GTK"
        echo "MINIMUM_LIBADWAITA=$LINUX_MIN_ADWAITA"
        echo "MINIMUM_GLIBC=$(objdump -T "$STAGE/usr/bin/$LINUX_EXECUTABLE" | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -n 1)"
        for file in "${ARTIFACTS[@]}"; do
            echo "ARTIFACT=$file"
        done
        echo "GIT_SHA=$git_sha"
        echo "GIT_REF=$git_ref"
        echo "GIT_DIRTY=$dirty"
        echo "SWIFT=$SWIFT_SUMMARY"
        echo "BUILD_SYSTEM=$SYSTEM_SUMMARY"
        echo "BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
            echo "CI_RUN=${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID"
        fi
    } >"$info"
}

run_package() {
    [[ $# -eq 0 ]] || usage
    toolchain_summary
    APP_VERSION=$(app_version)
    if [[ -n "${ART_RELEASE_TAG:-}" && "$ART_RELEASE_TAG" != "v$APP_VERSION" ]]; then
        fail "Tag $ART_RELEASE_TAG does not match AppVersion.current ($APP_VERSION); expected v$APP_VERSION."
    fi
    choose_product

    local resolved_output
    resolved_output=$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd -P)
    case "$resolved_output" in
        / | "$(cd "$HOME" && pwd -P)" | "$(cd "$REPO_ROOT" && pwd -P)" | "$(cd "$NATIVE_DIR" && pwd -P)" | "$(cd "$PROJECT_DIR" && pwd -P)")
            fail "ART_CI_OUTPUT_DIR must be a dedicated directory (it is emptied); got $OUTPUT_DIR" ;;
    esac
    rm -rf "$OUTPUT_DIR"
    mkdir -p "$LOG_DIR"
    STAGE=$(mktemp -d)/stage

    local scratch
    mapfile -t scratch < <(scratch_args AndroidRapidTransferLinux-release)
    note "Packaging $LINUX_APP_NAME $APP_VERSION ($PRODUCT) for $ARCH..."
    logged "$LOG_DIR/linux-build.log" "$SCRIPT_DIR/linux-build.sh" --product "$PRODUCT" --stage "$STAGE" \
        ${scratch[@]+"${scratch[@]}"} \
        || fail "linux-build.sh failed; see $LOG_DIR/linux-build.log"
    logged "$LOG_DIR/linux-package.log" "$SCRIPT_DIR/linux-package.sh" --stage "$STAGE" --output "$OUTPUT_DIR" all \
        || fail "linux-package.sh failed; see $LOG_DIR/linux-package.log"

    if [[ " $SELF_TESTS " == *" $PRODUCT "* ]]; then
        run_self_test "staged $LINUX_EXECUTABLE ($PRODUCT)" "$LOG_DIR/staged-self-test.log" \
            "$STAGE/usr/bin/$LINUX_EXECUTABLE"
        local appimage
        appimage=$(ls "$OUTPUT_DIR"/*.AppImage)
        APPIMAGE_EXTRACT_AND_RUN=1 run_self_test "$(basename "$appimage")" "$LOG_DIR/appimage-self-test.log" "$appimage"
    else
        note "No self-test for $PRODUCT (ART_LINUX_SELF_TESTS=$SELF_TESTS); launch not checked."
    fi

    ARTIFACTS=()
    local file
    for file in "$OUTPUT_DIR"/*.tar.gz "$OUTPUT_DIR"/*.AppImage "$OUTPUT_DIR"/*.AppImage.zsync "$OUTPUT_DIR"/*.deb "$OUTPUT_DIR"/*.rpm; do
        [[ -f "$file" ]] && ARTIFACTS+=("$(basename "$file")")
    done
    [[ ${#ARTIFACTS[@]} -ge 5 ]] || fail "Expected a tarball, AppImage, zsync, .deb and .rpm in $OUTPUT_DIR; got: ${ARTIFACTS[*]}"
    (cd "$OUTPUT_DIR" && sha256sum "${ARTIFACTS[@]}" >"SHA256SUMS-linux-$ARCH" && sha256sum -c --quiet "SHA256SUMS-linux-$ARCH")
    write_build_info "$OUTPUT_DIR/build-info-linux-$ARCH.txt"
    rm -rf "$(dirname "$STAGE")"

    local short_sha
    short_sha=$(git -C "$REPO_ROOT" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)
    set_output version "$APP_VERSION"
    set_output product "$PRODUCT"
    set_output output-dir "$OUTPUT_DIR"
    set_output artifact-name "$LINUX_ARTIFACT_NAME-$APP_VERSION-linux-$ARCH-$short_sha"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        {
            echo "### $LINUX_APP_NAME $APP_VERSION for Linux ($ARCH)"
            echo
            echo '```'
            cat "$OUTPUT_DIR/build-info-linux-$ARCH.txt"
            echo '```'
        } >>"$GITHUB_STEP_SUMMARY"
    fi
    note "Artifacts in $OUTPUT_DIR:"
    (cd "$OUTPUT_DIR" && ls -l)
    cat "$OUTPUT_DIR/build-info-linux-$ARCH.txt"
    echo "SUCCESS: $OUTPUT_DIR ($PRODUCT, $ARCH)"
}

MODE=${1:-}
[[ -n "$MODE" ]] || usage
shift
case "$MODE" in
    test) run_tests "$@" ;;
    package) run_package "$@" ;;
    *) usage ;;
esac
