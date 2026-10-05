# Sourced by the Linux packaging scripts: the app's identity on Linux and the
# system libraries it needs. The name and application ID mirror AppIdentity
# (native/ARTCore) and native/AndroidRapidTransfer/Scripts/release-config.sh;
# AppIdentityTests keeps them, the desktop entry and the AppStream metadata in
# step.

LINUX_APP_NAME="Android Rapid Transfer"
# Application ID: GApplication ID, desktop entry and AppStream ID, icon name.
LINUX_APP_ID="com.sameh.AndroidRapidTransfer"
# The installed command, /usr/bin/<executable>.
LINUX_EXECUTABLE="android-rapid-transfer"
# SwiftPM executable product built by default (Scripts/linux-build.sh --product).
LINUX_PRODUCT="android-rapid-transfer"
# Package name for the .deb and .rpm, and the doc directory.
LINUX_PACKAGE_NAME="android-rapid-transfer"
# URL-safe basename for release artifacts (tarball, AppImage).
LINUX_ARTIFACT_NAME="Android-Rapid-Transfer"
LINUX_SUMMARY="Move files between an Android phone and your computer"
LINUX_HOMEPAGE="https://github.com/sameh0/android-rapid-transfer"
LINUX_MAINTAINER="${LINUX_MAINTAINER:-Sameh <sameh0@users.noreply.github.com>}"
LINUX_LICENSE="MIT"

# Oldest runtime libraries the binary works with, from the newest symbols
# ARTGtk calls: AdwSpinner is libadwaita 1.6;
# gtk_css_provider_load_from_string and gtk_window_is_suspended are GTK 4.12.
LINUX_MIN_GTK="4.12"
LINUX_MIN_ADWAITA="1.6"
# Oldest headers the code compiles against: GtkReducedMotion is GTK 4.22.
LINUX_MIN_GTK_BUILD="4.22"

# Swift toolchain for release builds. 6.3.x: 6.4 cannot link FoundationEssentials
# with --static-swift-stdlib. The Ubuntu 24.04 tarball is used on newer
# distributions too (Scripts/linux-ci-setup.sh).
LINUX_SWIFT_VERSION="6.3.3"
