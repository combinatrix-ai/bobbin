#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
OUTPUT_DIR="${1:?pass an output directory}"
APP_PATH="$OUTPUT_DIR/Tiny Harness.app"

if [[ -e "$APP_PATH" ]]; then
  print -u2 "Refusing to overwrite existing app: $APP_PATH"
  exit 1
fi

cd "$PROJECT_DIR"
swift build -c release

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$PROJECT_DIR/.build/arm64-apple-macosx/release/TinyHarnessGUI" "$APP_PATH/Contents/MacOS/TinyHarnessGUI"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
chmod 755 "$APP_PATH/Contents/MacOS/TinyHarnessGUI"
codesign --force --deep --sign - "$APP_PATH"

print "$APP_PATH"
