#!/usr/bin/env bash
#
# dmg.sh — package dist/OpenTab.app into a distributable disk image.
#
# Produces dist/OpenTab-<version>.dmg containing the app and a symlink to
# /Applications, plus a .sha256 checksum file for the Homebrew cask.
#
# Usage: Scripts/dmg.sh

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

VERSION="$(tr -d '[:space:]' < VERSION)"
APP="$ROOT/dist/OpenTab.app"
DMG="$ROOT/dist/OpenTab-$VERSION.dmg"
STAGE="$ROOT/dist/dmg-stage"

if [[ ! -d "$APP" ]]; then
    echo "dmg.sh: $APP not found — run Scripts/bundle.sh first" >&2
    exit 1
fi

echo "==> Staging disk image contents"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/OpenTab.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $DMG"
hdiutil create \
    -volname "OpenTab $VERSION" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

rm -rf "$STAGE"

shasum -a 256 "$DMG" | awk '{print $1}' > "$DMG.sha256"

echo "==> Built $DMG"
echo "    sha256: $(cat "$DMG.sha256")"
