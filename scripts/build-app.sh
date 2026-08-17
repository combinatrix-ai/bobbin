#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
OUTPUT_DIR="${1:?pass an output directory}"
APP_PATH="$OUTPUT_DIR/Bobbin.app"

if [[ -e "$APP_PATH" ]]; then
  print -u2 "Refusing to overwrite existing app: $APP_PATH"
  exit 1
fi

cd "$PROJECT_DIR"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH/Bobbin" "$APP_PATH/Contents/MacOS/Bobbin"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
chmod 755 "$APP_PATH/Contents/MacOS/Bobbin"

# The icon is generated from Sources/BobbinIcon rather than checked in, so
# the bundle can never ship a mark that has drifted from the geometry source.
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
"$BIN_PATH/bobbin-icon" iconset "$ICONSET_DIR" >/dev/null
iconutil --convert icns "$ICONSET_DIR" --output "$APP_PATH/Contents/Resources/AppIcon.icns"
rm -rf "${ICONSET_DIR:h}"

codesign --force --deep --sign - "$APP_PATH"

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
codesign --verify --strict "$APP_PATH"

print "$APP_PATH"
