#!/bin/bash
set -euo pipefail
ROOT="$(dirname "$(realpath "$0")")"
OUTPUT="${1:-$(dirname "$ROOT")}"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/nexa-build.XXXXXX")"
APP="$BUILD/Nexa.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
echo "Building nexa for Apple Silicon..."
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 \
  "$ROOT/Metrics.swift" "$ROOT/Preferences.swift" "$ROOT/Brand.swift" \
  "$ROOT/AppActivity.swift" "$ROOT/ActivityView.swift" \
  "$ROOT/ActivityWindow.swift" "$ROOT/Views.swift" "$ROOT/App.swift" \
  -o "$APP/Contents/MacOS/Nexa"
xcrun swiftc -swift-version 5 -O "$ROOT/Brand.swift" "$ROOT/IconMaker.swift" -o "$BUILD/make-icon"
"$BUILD/make-icon" "$BUILD"
iconutil -c icns "$BUILD/Nexa.iconset" -o "$APP/Contents/Resources/Nexa.icns"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Assets/Manrope-Variable.woff2" "$ROOT/Assets/Manrope-OFL.txt" "$APP/Contents/Resources/"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - --options runtime "$APP"
codesign --verify --deep --strict "$APP"
if [ -e "$OUTPUT/Nexa.app" ]; then
  EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$OUTPUT/Nexa.app/Contents/Info.plist")"
  if [ "$EXISTING_ID" != "cn.nexastore.nexa" ]; then
    echo "Refusing to replace an unrelated application." >&2
    exit 1
  fi
fi
mkdir -p "$OUTPUT"
# Archive the verified bundle before a cloud-synced output folder adds metadata.
ditto -c -k --keepParent --norsrc "$APP" "$OUTPUT/Nexa-macOS.zip"
ditto --norsrc "$APP" "$OUTPUT/Nexa.app"
cp "$BUILD/nexa-icon.png" "$OUTPUT/nexa-icon.png"
echo "Built: $OUTPUT/Nexa.app"
echo "Icon: $OUTPUT/nexa-icon.png"
echo "Build workspace: $BUILD"
