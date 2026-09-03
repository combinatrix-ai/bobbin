#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
OUTPUT_DIR="${1:?pass an output directory}"
APP_PATH="$OUTPUT_DIR/Bobbin.app"
APP_VERSION="${APP_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PROJECT_DIR/Resources/Info.plist")}"
UNIVERSAL="${UNIVERSAL:-0}"
DISTRIBUTION="${DISTRIBUTION:-0}"

if [[ -e "$APP_PATH" ]]; then
  print -u2 "Refusing to overwrite existing app: $APP_PATH"
  exit 1
fi

cd "$PROJECT_DIR"
build_args=(-c release)
if [[ "$UNIVERSAL" == "1" ]]; then
  build_args+=(--arch arm64 --arch x86_64)
fi
swift build "${build_args[@]}"
BIN_PATH="$(swift build "${build_args[@]}" --show-bin-path)"

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH/Bobbin" "$APP_PATH/Contents/MacOS/Bobbin"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP_PATH/Contents/Info.plist"
chmod 755 "$APP_PATH/Contents/MacOS/Bobbin"

# SwiftPM links Sparkle but does not copy its dynamic framework into a hand-made
# app bundle. Embed it and add the conventional framework search path.
SPARKLE_SOURCE="$BIN_PATH/Sparkle.framework"
if [[ ! -d "$SPARKLE_SOURCE" ]]; then
  print -u2 "Missing Sparkle.framework at $SPARKLE_SOURCE"
  exit 1
fi
mkdir -p "$APP_PATH/Contents/Frameworks"
cp -R "$SPARKLE_SOURCE" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@loader_path/../Frameworks" "$APP_PATH/Contents/MacOS/Bobbin"

# The icon is generated from Sources/BobbinIcon rather than checked in, so
# the bundle can never ship a mark that has drifted from the geometry source.
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
"$BIN_PATH/bobbin-icon" iconset "$ICONSET_DIR" >/dev/null
iconutil --convert icns "$ICONSET_DIR" --output "$APP_PATH/Contents/Resources/AppIcon.icns"
rm -rf "${ICONSET_DIR:h}"

if [[ "$DISTRIBUTION" == "1" ]]; then
  CODESIGN_IDENTITY="${CODESIGN_IDENTITY:?Set CODESIGN_IDENTITY for a distribution build}"
  codesign_args=(--force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp)
else
  codesign_args=(--force --sign - --timestamp=none)
fi

# Sign Sparkle's nested helpers inside-out before sealing the framework and app.
SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE_FRAMEWORK/Versions/B"
for nested in \
  "$SPARKLE_VERSION/XPCServices/Downloader.xpc" \
  "$SPARKLE_VERSION/XPCServices/Installer.xpc" \
  "$SPARKLE_VERSION/Autoupdate" \
  "$SPARKLE_VERSION/Updater.app"; do
  [[ -e "$nested" ]] && codesign "${codesign_args[@]}" "$nested"
done
codesign "${codesign_args[@]}" "$SPARKLE_FRAMEWORK"
codesign "${codesign_args[@]}" "$APP_PATH"

# Verification: a bundle that builds but has no usable icon should fail here
# rather than reach the Dock.
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist")"
if [[ ! -x "$APP_PATH/Contents/MacOS/$EXECUTABLE" ]]; then
  print -u2 "Info.plist declares CFBundleExecutable='$EXECUTABLE' but no such executable is present"
  exit 1
fi
ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP_PATH/Contents/Info.plist")"
if [[ "$ICON_NAME" != "AppIcon" ]]; then
  print -u2 "Info.plist declares CFBundleIconFile='$ICON_NAME', expected 'AppIcon'"
  exit 1
fi
if [[ ! -s "$APP_PATH/Contents/Resources/$ICON_NAME.icns" ]]; then
  print -u2 "Missing or empty icon resource: Contents/Resources/$ICON_NAME.icns"
  exit 1
fi
# iconutil is happy to emit an .icns holding fewer representations than asked
# for, so confirm the largest one actually landed.
if ! sips -g pixelWidth "$APP_PATH/Contents/Resources/$ICON_NAME.icns" 2>/dev/null | grep -q 'pixelWidth: 1024'; then
  print -u2 "Icon resource does not contain the expected 1024 px representation"
  exit 1
fi
codesign --verify --deep --strict "$APP_PATH"

if [[ "$UNIVERSAL" == "1" ]]; then
  ARCHITECTURES="$(lipo -archs "$APP_PATH/Contents/MacOS/$EXECUTABLE")"
  if [[ "$ARCHITECTURES" != *arm64* || "$ARCHITECTURES" != *x86_64* ]]; then
    print -u2 "Expected a universal executable, found: $ARCHITECTURES"
    exit 1
  fi
fi

print "$APP_PATH"
