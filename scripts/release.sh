#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")"
BUILD_NUMBER="${BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PROJECT_DIR/Resources/Info.plist")}"
TAG="${TAG:-v$APP_VERSION}"
NOTARY_PROFILE="${NOTARY_PROFILE:-until-notary}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: COMBINATRIX K.K. (3Y275A5TZ8)}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/dist/$TAG}"
APP_PATH="$OUTPUT_DIR/Bobbin.app"
DMG_PATH="$OUTPUT_DIR/Bobbin-$TAG.dmg"
ZIP_PATH="$OUTPUT_DIR/Bobbin-$TAG.zip"
CHECKSUM_PATH="$OUTPUT_DIR/Bobbin-$TAG-checksums.txt"
APPCAST_PATH="$OUTPUT_DIR/appcast.xml"

if [[ "$TAG" != "v$APP_VERSION" ]]; then
  print -u2 "Tag $TAG does not match bundle version $APP_VERSION"
  exit 1
fi

if [[ -e "$OUTPUT_DIR" ]]; then
  print -u2 "Refusing to overwrite existing release directory: $OUTPUT_DIR"
  exit 1
fi
mkdir -p "$OUTPUT_DIR"

APP_VERSION="$APP_VERSION" \
BUILD_NUMBER="$BUILD_NUMBER" \
UNIVERSAL=1 \
DISTRIBUTION=1 \
CODESIGN_IDENTITY="$CODESIGN_IDENTITY" \
"$SCRIPT_DIR/build-app.sh" "$OUTPUT_DIR"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# Apple notarizes an archive of the app. Staple the accepted ticket to the app,
# then recreate the downloadable zip so the ticket remains available offline.
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
rm "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

# Sign the final ZIP after the notarization ticket has been stapled and the
# archive recreated. Signing the pre-staple archive would leave an appcast
# signature that cannot authenticate the actual download.
APP_DIR="$APP_PATH" \
ZIP_PATH="$ZIP_PATH" \
DOWNLOAD_URL="https://github.com/combinatrix-ai/bobbin/releases/download/$TAG/${ZIP_PATH:t}" \
OUT="$APPCAST_PATH" \
"$SCRIPT_DIR/make-appcast.sh"

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname "Bobbin" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
codesign --sign "$CODESIGN_IDENTITY" --timestamp "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"

xcrun stapler validate "$APP_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

(
  cd "$OUTPUT_DIR"
  shasum -a 256 "${DMG_PATH:t}" "${ZIP_PATH:t}" "${APPCAST_PATH:t}" > "${CHECKSUM_PATH:t}"
)

print "Release ready:"
print "  $DMG_PATH"
print "  $ZIP_PATH"
print "  $APPCAST_PATH"
print "  $CHECKSUM_PATH"
