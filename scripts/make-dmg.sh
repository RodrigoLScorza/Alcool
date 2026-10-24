#!/bin/bash
#
# make-dmg.sh
#
# This file is part of Whisky.
#
# Whisky is free software: you can redistribute it and/or modify it under the terms
# of the GNU General Public License as published by the Free Software Foundation,
# either version 3 of the License, or (at your option) any later version.
#
# Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
# without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with Whisky.
# If not, see https://www.gnu.org/licenses/.
#
# Builds Alcool.app in Release and packages it as a DMG with a link to
# Applications, without an Apple developer account.
#
# The app is signed ad hoc, not with a Developer ID, and is not notarized:
# it opens normally on the Mac that built it, but on any other Mac, macOS
# blocks the first launch until the user clicks "Open Anyway" in
# System Settings > Privacy & Security. Use release.sh once Alcool has a
# Developer ID for a DMG that opens anywhere without that step.
#
# Usage: scripts/make-dmg.sh [version]
# Example: scripts/make-dmg.sh 0.1.0
# Without a version, the one in the Xcode project is used.

set -euo pipefail

VERSION="${1:-}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/dmg"
DERIVED_DIR="$BUILD_DIR/derived"
STAGE_DIR="$BUILD_DIR/stage"
APP_PATH="$DERIVED_DIR/Build/Products/Release/Alcool.app"

cd "$PROJECT_DIR"
mkdir -p "$BUILD_DIR"

# Every target (app, CLI, thumbnail extension) gets the same version, which
# macOS requires of an app and its extensions.
VERSION_SETTINGS=()
if [ -n "$VERSION" ]; then
    VERSION_SETTINGS=("MARKETING_VERSION=$VERSION")
fi

echo "==> Building Alcool (Release, Apple Silicon)"
xcodebuild \
    -project Whisky.xcodeproj \
    -scheme Whisky \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DIR" \
    ARCHS=arm64 \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" \
    ENABLE_HARDENED_RUNTIME=NO \
    SKIP_SWIFTLINT_BUILD_PHASE=YES \
    ${VERSION_SETTINGS[@]+"${VERSION_SETTINGS[@]}"} \
    -quiet \
    build

[ -d "$APP_PATH" ] || { echo "Alcool.app not found at $APP_PATH"; exit 1; }
VERSION="$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString)"
DMG_PATH="$BUILD_DIR/Alcool-$VERSION.dmg"

echo "==> Checking the signature"
codesign --verify --deep --strict "$APP_PATH"

echo "==> Building $(basename "$DMG_PATH")"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "Alcool $VERSION" \
    -srcfolder "$STAGE_DIR" \
    -ov -format UDZO \
    -quiet \
    "$DMG_PATH"
rm -rf "$STAGE_DIR"

echo
echo "DMG: $DMG_PATH"
shasum -a 256 "$DMG_PATH"
