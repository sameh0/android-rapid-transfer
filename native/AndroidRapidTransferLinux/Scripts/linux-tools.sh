# Sourced by the Linux packaging scripts: the third-party files they download,
# each pinned to a version and a SHA-256, and a cached, verified fetch.
#
#   path=$(fetch_tool <name>)     downloads (once) and verifies; prints the path
#   verify_tool <name> <file>     fails unless <file> has the pinned checksum
#
# Files are cached in ART_LINUX_TOOLS_DIR (default ~/.cache/art-linux-tools).
# To update a tool, change its URL and checksum together.

ART_LINUX_TOOLS_DIR=${ART_LINUX_TOOLS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/art-linux-tools}

# name -> "url sha256"
tool_spec() {
    case "$1" in
        # appimagetool 1.9.1 and the static type2 runtime it embeds (no FUSE 2
        # needed on the user's machine).
        appimagetool_x86_64) echo "https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0" ;;
        appimagetool_aarch64) echo "https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-aarch64.AppImage f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158" ;;
        appimage_runtime_x86_64) echo "https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64 2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d" ;;
        appimage_runtime_aarch64) echo "https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-aarch64 00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444" ;;
        # nfpm 2.47.0 (static Go binary): builds the .deb and .rpm.
        nfpm_x86_64) echo "https://github.com/goreleaser/nfpm/releases/download/v2.47.0/nfpm_2.47.0_Linux_x86_64.tar.gz 0660ca602b2d2d2ae4781a06c692b3eeb9d437ffea05b831d76e41f4a3188783" ;;
        nfpm_aarch64) echo "https://github.com/goreleaser/nfpm/releases/download/v2.47.0/nfpm_2.47.0_Linux_arm64.tar.gz 1c0f5f2999b9a974bfb04fdb0cc3306096de530ac5dbb25d739cc5f5219c919c" ;;
        # Swift 6.3.3 for Ubuntu 24.04 (Scripts/linux-ci-setup.sh).
        swift_x86_64) echo "https://download.swift.org/swift-6.3.3-release/ubuntu2404/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE-ubuntu24.04.tar.gz da8272a5fddccd65b1529ed0e52e04526e2eadd4237d58d6220efeb973c6cd19" ;;
        swift_aarch64) echo "https://download.swift.org/swift-6.3.3-release/ubuntu2404-aarch64/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE-ubuntu24.04-aarch64.tar.gz 47126395429653fa768d370655876ec1b68f6a95c7884f5e4f179700141c9b7f" ;;
        # Ubuntu 24.04's libxml2.so.2 and the ICU it links, for the Swift 6.3
        # tools on Ubuntu 26.04 (Scripts/linux-ci-setup.sh).
        libxml2_amd64) echo "http://archive.ubuntu.com/ubuntu/pool/main/libx/libxml2/libxml2_2.9.14+dfsg-1.3ubuntu3_amd64.deb 8c4efd7abe155df3cf0f9b64d659f2d866215785f8e8c44234fbb341d58cc967" ;;
        libxml2_arm64) echo "http://ports.ubuntu.com/ubuntu-ports/pool/main/libx/libxml2/libxml2_2.9.14+dfsg-1.3ubuntu3_arm64.deb 6045818c821a498cfa2b9c93deeac87db5d0d6bd07f160176f1073af0c2858e4" ;;
        libicu74_amd64) echo "http://archive.ubuntu.com/ubuntu/pool/main/i/icu/libicu74_74.2-1ubuntu3_amd64.deb d29c97a21a3e3254731cfac186e4d4e611e5e67d2c9a0430f6acfbd9acaefa2e" ;;
        libicu74_arm64) echo "http://ports.ubuntu.com/ubuntu-ports/pool/main/i/icu/libicu74_74.2-1ubuntu3_arm64.deb 041df33ab32c57287a62ba141890a82512bf092854be455259c8034ab7ae9fbc" ;;
        *) echo "ERROR: unknown tool '$1'" >&2; return 1 ;;
    esac
}

verify_tool() {
    local name=$1 file=$2 spec expected actual
    spec=$(tool_spec "$name") || return 1
    expected=${spec##* }
    actual=$(sha256sum "$file" | cut -d' ' -f1)
    if [[ "$actual" != "$expected" ]]; then
        echo "ERROR: $file has SHA-256 $actual; expected $expected for $name" >&2
        return 1
    fi
}

fetch_tool() {
    local name=$1 spec url file partial
    spec=$(tool_spec "$name") || return 1
    url=${spec% *}
    # Cached under the checksum, so a new pin never reuses an old download.
    file="$ART_LINUX_TOOLS_DIR/${spec##* }/${url##*/}"
    if [[ ! -f "$file" ]]; then
        mkdir -p "$(dirname "$file")"
        partial="$file.partial.$$"
        echo "Downloading $url" >&2
        curl --fail --location --silent --show-error --retry 3 --output "$partial" "$url" || { rm -f "$partial"; return 1; }
        verify_tool "$name" "$partial" || { rm -f "$partial"; return 1; }
        mv "$partial" "$file"
    else
        verify_tool "$name" "$file" || return 1
    fi
    echo "$file"
}
