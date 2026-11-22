#!/bin/sh
# Builds "MessageSift Connector.dmg" (the app plus an Applications link) from an exported, Developer ID signed app.
#   Scripts/make_dmg.sh "/path/to/MessageSift Connector.app"
# Then notarize and staple:
#   xcrun notarytool submit "build/MessageSift Connector.dmg" --keychain-profile <profile> --wait
#   xcrun stapler staple "build/MessageSift Connector.dmg"
set -e
APP="$1"
[ -d "$APP" ] || { echo "usage: $0 \"/path/to/MessageSift Connector.app\""; exit 1; }
OUT="build/MessageSift Connector.dmg"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/MessageSift Connector.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p build
rm -f "$OUT"
hdiutil create -volname "MessageSift Connector" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
rm -rf "$STAGE"
echo "$OUT"
