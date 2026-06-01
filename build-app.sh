#!/usr/bin/env bash
#
# Build Lyrify and assemble a double-clickable Lyrify.app — no terminal needed.
#
# Usage:
#   ./build-app.sh             # builds and drops Lyrify.app on the Desktop
#   ./build-app.sh /Applications   # or any destination directory
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:-$HOME/Desktop}"
APP="$DEST/Lyrify.app"

echo "▸ Building release binary…"
swift build -c release --package-path "$ROOT"
BIN="$ROOT/.build/release/Lyrify"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN"                    "$APP/Contents/MacOS/Lyrify"
cp "$ROOT/app/Info.plist"   "$APP/Contents/Info.plist"
cp "$ROOT/app/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc code signature so macOS treats the bundle as a valid app.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# Nudge Launch Services so Finder shows the new icon immediately.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" || true
touch "$APP"

echo "✓ Done — double-click $APP to launch (Spotify must be running)."
