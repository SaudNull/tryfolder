#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CONFIGURATION="${1:-debug}"
case "$CONFIGURATION" in debug|release) ;; *) echo 'Usage: script/build.sh [debug|release]' >&2; exit 2;; esac
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.cache/swift"
mkdir -p "$ROOT_DIR/.cache" "$ROOT_DIR/dist"
swift build --configuration "$CONFIGURATION" --arch arm64 --scratch-path "$ROOT_DIR/.build" --cache-path "$ROOT_DIR/.cache/swiftpm" --product TryFolder
BIN_DIR="$(swift build --configuration "$CONFIGURATION" --arch arm64 --scratch-path "$ROOT_DIR/.build" --cache-path "$ROOT_DIR/.cache/swiftpm" --show-bin-path)"
APP="$ROOT_DIR/dist/TryFolder.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/TryFolder" "$APP/Contents/MacOS/TryFolder"
chmod 755 "$APP/Contents/MacOS/TryFolder"
cp "$ROOT_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ ! -f "$ROOT_DIR/.build/TryFolder.icns" ] || [ "$ROOT_DIR/script/make_icon.swift" -nt "$ROOT_DIR/.build/TryFolder.icns" ]; then
  swift "$ROOT_DIR/script/make_icon.swift" "$ROOT_DIR/.build"
  iconutil -c icns "$ROOT_DIR/.build/TryFolder.iconset" -o "$ROOT_DIR/.build/TryFolder.icns"
fi
cp "$ROOT_DIR/.build/TryFolder.icns" "$APP/Contents/Resources/TryFolder.icns"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --verify --strict "$APP"
printf 'Built %s (%s, Apple Silicon, ad-hoc signed)\n' "$APP" "$CONFIGURATION"
