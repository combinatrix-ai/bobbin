#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="${APP_DIR:?Set APP_DIR to the built Bobbin.app}"
ZIP_PATH="${ZIP_PATH:?Set ZIP_PATH to the update ZIP}"
DOWNLOAD_URL="${DOWNLOAD_URL:?Set DOWNLOAD_URL to the public ZIP URL}"
OUT="${OUT:-$PROJECT_DIR/appcast.xml}"

PLIST="$APP_DIR/Contents/Info.plist"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
SIGN_UPDATE="$(find "$PROJECT_DIR/.build/artifacts" -name sign_update -type f 2>/dev/null | head -n 1)"

if [[ -z "$SIGN_UPDATE" ]]; then
  print -u2 "Sparkle sign_update tool not found; run swift build first"
  exit 1
fi

if [[ -n "${ED_KEY_FILE:-}" ]]; then
  ENCLOSURE_ATTRIBUTES="$("$SIGN_UPDATE" "$ZIP_PATH" --ed-key-file "$ED_KEY_FILE")"
else
  ENCLOSURE_ATTRIBUTES="$("$SIGN_UPDATE" "$ZIP_PATH")"
fi
PUBLICATION_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Bobbin</title>
    <link>https://bobbin.combinatrix.ai/</link>
    <description>Most recent updates to Bobbin.</description>
    <language>en</language>
    <item>
      <title>Version ${SHORT_VERSION}</title>
      <pubDate>${PUBLICATION_DATE}</pubDate>
      <sparkle:version>${BUILD_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_SYSTEM}</sparkle:minimumSystemVersion>
      <enclosure url="${DOWNLOAD_URL}" ${ENCLOSURE_ATTRIBUTES} type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

print "Wrote appcast: $OUT (v$SHORT_VERSION build $BUILD_VERSION)"
