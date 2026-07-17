#!/usr/bin/env bash

# Regenerates Resources/AppIcon.icns from AppIconArtwork (the icon is drawn in
# code, so every size comes from one source). Run it after changing
# Sources/AndroidRapidTransferCore/AppIconArtwork.swift and commit the result;
# the packaging scripts copy the committed file into the bundle, and
# AppIconArtworkTests fails while the two disagree.
#
#   Scripts/make-app-icon.sh

set -euo pipefail

if [[ $# -gt 0 ]]; then
    echo "Usage: $0" >&2
    exit 2
fi

PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$PROJECT_DIR"
swift run --disable-sandbox AppIconGenerator "$PROJECT_DIR/Resources/AppIcon.icns"
