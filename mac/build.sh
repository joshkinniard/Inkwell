#!/bin/bash
# Build Inkwell.app as a universal (Intel + Apple Silicon) macOS app using only
# the Command Line Tools (no Xcode required). Run:  ./build.sh
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/Sources"
BUILD="$HERE/build"
APP="$BUILD/Inkwell.app"
DEPLOY="14.0"
# Optional app icon. Drop an AppIcon.icns next to this script, or point
# INKWELL_ICON at one. Without it the app builds with the generic icon.
ICON_SRC="${INKWELL_ICON:-$HERE/AppIcon.icns}"

echo "==> Cleaning"
rm -rf "$BUILD"
mkdir -p "$BUILD/obj"

echo "==> Compiling x86_64"
swiftc -target "x86_64-apple-macosx$DEPLOY" "$SRC"/*.swift -o "$BUILD/obj/Inkwell-x86_64"

echo "==> Compiling arm64 (this is the slow one, cross-compiled from Intel)"
swiftc -target "arm64-apple-macosx$DEPLOY" "$SRC"/*.swift -o "$BUILD/obj/Inkwell-arm64"

echo "==> Merging universal binary"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$BUILD/obj/Inkwell-x86_64" "$BUILD/obj/Inkwell-arm64" -output "$APP/Contents/MacOS/Inkwell"

echo "==> Assembling bundle"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "!! icon not found at $ICON_SRC — building without it"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Ad-hoc code signing"
# Strip extended attributes (iCloud/Finder metadata on copied files) that codesign rejects.
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"

rm -rf "$BUILD/obj"

# By default the build stops here and leaves Inkwell.app in build/ for you to
# drag wherever you like. To have the script install it for you as well:
#
#     INKWELL_INSTALL=1 ./build.sh              # -> /Applications
#     INKWELL_INSTALL=~/Applications ./build.sh # -> somewhere else
#
# Note this REPLACES any Inkwell.app already sitting in that folder.
if [ -n "${INKWELL_INSTALL:-}" ]; then
  if [ "$INKWELL_INSTALL" = "1" ]; then
    INSTALL_DIR="/Applications"
  else
    INSTALL_DIR="$INKWELL_INSTALL"
  fi
  INSTALL="$INSTALL_DIR/Inkwell.app"
  mkdir -p "$INSTALL_DIR"
  echo "==> Installing to $INSTALL"
  rm -rf "$INSTALL"
  cp -R "$APP" "$INSTALL"
  xattr -cr "$INSTALL"
  codesign --force --deep --sign - "$INSTALL"
fi

echo "==> Done: $APP"
lipo -info "$APP/Contents/MacOS/Inkwell"
