# Sourced by the packaging scripts. The single place that defines where the app
# looks for updates, which key verifies them, and how builds are numbered.

# The app's identity. The app reads its user-facing name from the bundle
# (AndroidRapidTransferCore's AppIdentity), so a rename starts here.
#
# CFBundleName is also the application menu's title. Apple suggests keeping it
# under 16 characters, but it is a recommendation rather than a limit, and the
# full name is what users search for — Google's own Android File Transfer used
# a 21-character name — so the bundle name and display name are the same.
APP_DISPLAY_NAME="Android Rapid Transfer"
APP_BUNDLE_NAME="$APP_DISPLAY_NAME"
APP_BUNDLE_ID="com.sameh.AndroidRapidTransfer"
# SwiftPM executable product name, i.e. Contents/MacOS/<executable>.
APP_EXECUTABLE="AndroidRapidTransfer"
# URL-safe basename for release artifacts (DMG, release notes).
APP_ARTIFACT_NAME="Android-Rapid-Transfer"
COPYRIGHT_HOLDER="${COPYRIGHT_HOLDER:-Sameh}"

# NSHumanReadableCopyright: shown in the About panel and Finder's Get Info.
# The app's private drag-and-drop types (LocalDragPayload, DeviceDragPayload:
# UTType(exportedAs:) in Swift), declared in Info.plist as Apple requires for
# exported types. Identifiers use the release bundle ID in every build, as the
# Swift code does. Printed as the plist fragment both packaging scripts embed.
exported_type_declarations() {
    local identifier description
    echo "    <key>UTExportedTypeDeclarations</key>"
    echo "    <array>"
    for identifier in local-items device-items; do
        case "$identifier" in
            local-items) description="$APP_DISPLAY_NAME Mac items" ;;
            device-items) description="$APP_DISPLAY_NAME phone items" ;;
        esac
        cat <<TYPE
        <dict>
            <key>UTTypeIdentifier</key>
            <string>$APP_BUNDLE_ID.$identifier</string>
            <key>UTTypeDescription</key>
            <string>$description</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
        </dict>
TYPE
    done
    echo "    </array>"
}

copyright_notice() {
    echo "Copyright © $(date +%Y) $COPYRIGHT_HOLDER."
}

# Third-party license notices, which every distributed copy must include. The
# app's Acknowledgements window reads them from Contents/Resources. Usage:
#   install_acknowledgements <project dir> <Contents>
install_acknowledgements() {
    if [[ $# -ne 2 ]]; then
        echo "Usage: install_acknowledgements <project dir> <Contents>" >&2
        return 2
    fi
    local project_dir=$1 contents=$2
    local source="$project_dir/Resources/Acknowledgements.txt"
    if [[ ! -f "$source" ]]; then
        echo "ERROR: Missing $source" >&2
        return 1
    fi
    mkdir -p "$contents/Resources"
    cp "$source" "$contents/Resources/Acknowledgements.txt"
}

# The app icon, rendered by Scripts/make-app-icon.sh and committed. Info.plist
# names it with CFBundleIconFile=$APP_ICON_NAME. Usage:
#   install_app_icon <project dir> <Contents>
APP_ICON_NAME="AppIcon"
install_app_icon() {
    if [[ $# -ne 2 ]]; then
        echo "Usage: install_app_icon <project dir> <Contents>" >&2
        return 2
    fi
    local project_dir=$1 contents=$2
    local source="$project_dir/Resources/$APP_ICON_NAME.icns"
    if [[ ! -f "$source" ]]; then
        echo "ERROR: Missing $source; run Scripts/make-app-icon.sh" >&2
        return 1
    fi
    mkdir -p "$contents/Resources"
    cp "$source" "$contents/Resources/$APP_ICON_NAME.icns"
}

# Fails unless the bundle's code is exactly what the packaging scripts put
# there: the app's executable in Contents/MacOS and Sparkle in
# Contents/Frameworks. A stray helper binary or dylib (a leftover from a local
# experiment, say) would otherwise ship, signed, to every user. Usage:
#   verify_bundle_layout <App.app>
verify_bundle_layout() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: verify_bundle_layout <App.app>" >&2
        return 2
    fi
    local app=$1
    local contents="$app/Contents" problems=() item name
    [[ -d "$contents" ]] || { echo "ERROR: $app has no Contents directory" >&2; return 1; }
    [[ -x "$contents/MacOS/$APP_EXECUTABLE" ]] || problems+=("missing MacOS/$APP_EXECUTABLE")

    for item in "$contents/MacOS"/* "$contents/Frameworks"/*; do
        [[ -e "$item" || -L "$item" ]] || continue
        name=${item#"$contents/"}
        case "$name" in
            "MacOS/$APP_EXECUTABLE" | "Frameworks/Sparkle.framework") ;;
            *) problems+=("unexpected $name") ;;
        esac
    done

    if [[ ${#problems[@]} -ne 0 ]]; then
        echo "ERROR: $app does not have the expected layout:" >&2
        printf '  %s\n' "${problems[@]}" >&2
        return 1
    fi
    echo "Bundle layout: verified."
}

# Appcast for automatic updates. It is uploaded as an asset of the most recent
# non-prerelease GitHub release, which is what `releases/latest` resolves to.
# Requires the GitHub repository to be named sameh0/android-rapid-transfer.
SPARKLE_FEED_URL="https://github.com/sameh0/android-rapid-transfer/releases/latest/download/appcast.xml"

# Homebrew: the tap repository and the cask in it, which .github/workflows/
# homebrew.yml points at each published release (update-homebrew-cask.sh).
# Users install with `brew install --cask sameh0/tap/android-rapid-transfer`.
HOMEBREW_TAP_REPOSITORY="sameh0/homebrew-tap"
HOMEBREW_CASK_PATH="Casks/android-rapid-transfer.rb"

# Public half of the EdDSA key that signs update archives. The private half
# lives only in the release maintainer's login keychain (Sparkle's
# generate_keys); it is never written to the repository or to disk.
SPARKLE_PUBLIC_ED_KEY="+7P4sG+BXv+z20ipGYXj50A7jB/ebSYrQUt/ghUCslQ="

# CFBundleVersion. Sparkle orders updates by it, so it must grow with every
# release. Defaults to the commit count of HEAD, which only grows on a linear
# release branch; set BUILD_NUMBER explicitly (for example from CI) otherwise.
resolve_build_number() {
    local repo_root=$1
    local number=${BUILD_NUMBER:-$(git -C "$repo_root" rev-list --count HEAD)}
    if [[ ! "$number" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: BUILD_NUMBER must be a positive integer; got '$number'" >&2
        return 1
    fi
    echo "$number"
}

# The universal Sparkle.framework SwiftPM resolved for the pinned version.
sparkle_framework_source() {
    local project_dir=$1
    local framework="$project_dir/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    if [[ ! -d "$framework" ]]; then
        echo "ERROR: Missing $framework; resolve packages with swift build first" >&2
        return 1
    fi
    echo "$framework"
}

# Sparkle's command-line tools (generate_keys, generate_appcast, sign_update).
sparkle_tools_dir() {
    echo "$1/.build/artifacts/sparkle/Sparkle/bin"
}

# Signs Sparkle's nested helpers inside-out, then the framework, in the order
# Sparkle documents for apps that are not sandboxed. Usage:
#   sign_sparkle_framework <Sparkle.framework> <identity|-> [codesign flags...]
sign_sparkle_framework() {
    local framework=$1 identity=$2
    shift 2
    local version="$framework/Versions/B"
    /usr/bin/codesign --force --sign "$identity" "$@" "$version/XPCServices/Installer.xpc"
    /usr/bin/codesign --force --sign "$identity" "$@" \
        --preserve-metadata=entitlements "$version/XPCServices/Downloader.xpc"
    /usr/bin/codesign --force --sign "$identity" "$@" "$version/Autoupdate"
    /usr/bin/codesign --force --sign "$identity" "$@" "$version/Updater.app"
    /usr/bin/codesign --force --sign "$identity" "$@" "$framework"
}
