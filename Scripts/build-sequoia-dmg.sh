#!/bin/bash
# Build an unsigned Tinycast.app into build/Tinycast-<version>.dmg for Intel (x86_64).
#
# Usage:
#   ./Scripts/build-dmg.sh [version]
#
# The script verifies that the resulting application contains an x86_64
# executable before creating the DMG.

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

MACOS_MIN_VERSION="15.6"
DERIVED="build/DerivedData"
APP="$DERIVED/Build/Products/Release/Tinycast.app"
DMG=""
STAGE=""

cleanup() {
    if [[ -n "$STAGE" && -d "$STAGE" ]]; then
        rm -rf "$STAGE"
    fi

    # If the script failed while creating the DMG, don't leave a corrupt/
    # incomplete DMG behind.
    if [[ "${BUILD_FAILED:-0}" == "1" && -n "$DMG" ]]; then
        rm -f "$DMG"
    fi
}

BUILD_FAILED=1
trap cleanup EXIT INT TERM

echo "▸ Building Tinycast.app for Intel (Release)…"

xcodebuild \
    -project Tinycast.xcodeproj \
    -scheme Tinycast \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN_VERSION" \
    ARCHS=x86_64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    ${1:+MARKETING_VERSION="$1"} \
    build

# ---------------------------------------------------------------------------
# Verify the application bundle exists.
# ---------------------------------------------------------------------------

if [[ ! -d "$APP" ]]; then
    echo "✗ Expected application was not created:"
    echo "  $APP"
    exit 1
fi

echo "▸ Verifying application…"

EXECUTABLE="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleExecutable' \
    "$APP/Contents/Info.plist" 2>/dev/null || true)"

if [[ -z "$EXECUTABLE" ]]; then
    echo "✗ CFBundleExecutable is missing from Info.plist"
    exit 1
fi

APP_BINARY="$APP/Contents/MacOS/$EXECUTABLE"

if [[ ! -f "$APP_BINARY" ]]; then
    echo "✗ Application executable was not found:"
    echo "  $APP_BINARY"
    exit 1
fi

echo "  Executable: $EXECUTABLE"

# ---------------------------------------------------------------------------
# Verify architecture.
# ---------------------------------------------------------------------------

ARCHS_FOUND="$(file "$APP_BINARY")"

echo "  Binary:     $ARCHS_FOUND"

if ! lipo -info "$APP_BINARY" 2>/dev/null | grep -Eq 'x86_64'; then
    echo "✗ Application binary is not x86_64:"
    echo "  $APP_BINARY"
    echo "  $ARCHS_FOUND"
    exit 1
fi

# Make sure this isn't accidentally a universal binary. The build is
# explicitly intended to produce Intel only.
if lipo -info "$APP_BINARY" 2>/dev/null | grep -Eq 'arm64'; then
    echo "✗ Application binary unexpectedly contains arm64:"
    echo "  $(lipo -info "$APP_BINARY")"
    exit 1
fi

echo "  Architecture: x86_64 ✓"

# ---------------------------------------------------------------------------
# Read and validate the version.
# ---------------------------------------------------------------------------

VERSION="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist")"

if [[ -z "$VERSION" ]]; then
    echo "✗ CFBundleShortVersionString is empty"
    exit 1
fi

DMG="build/Tinycast-${VERSION}.dmg"

echo "  Version:      $VERSION"
echo "  Output:       $DMG"

# Never package over an existing DMG. Remove it first so a failure cannot
# leave the previous version looking like the newly generated one.
rm -f "$DMG"

# ---------------------------------------------------------------------------
# Stage the application.
# ---------------------------------------------------------------------------

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/tinycast-dmg.XXXXXX")"

echo "▸ Staging application…"

cp -R "$APP" "$STAGE/Tinycast.app"
ln -s /Applications "$STAGE/Applications"

# ---------------------------------------------------------------------------
# Create DMG.
# ---------------------------------------------------------------------------

echo "▸ Creating ${DMG}…"

if ! hdiutil create \
    -srcfolder "$STAGE" \
    -volname "Tinycast" \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null; then

    echo "✗ Failed to create DMG"
    exit 1
fi

# ---------------------------------------------------------------------------
# Verify the DMG actually exists and is readable.
# ---------------------------------------------------------------------------

if [[ ! -f "$DMG" ]]; then
    echo "✗ hdiutil reported success, but DMG was not created:"
    echo "  $DMG"
    exit 1
fi

echo "▸ Verifying DMG…"

if ! hdiutil imageinfo "$DMG" >/dev/null 2>&1; then
    echo "✗ DMG failed verification:"
    echo "  $DMG"
    rm -f "$DMG"
    exit 1
fi

BUILD_FAILED=0

echo
echo "✓ Build complete"
echo "  App: $APP"
echo "  Arch: x86_64"
echo "  Version: $VERSION"
echo "  DMG: $DMG"