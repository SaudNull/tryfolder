#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT_DIR/script/build.sh" release
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT_DIR/dist/TryFolder.app/Contents/Info.plist")"
ARCHIVE="$ROOT_DIR/dist/TryFolder-$VERSION-macos-arm64-local.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$ROOT_DIR/dist/TryFolder.app" "$ARCHIVE"
(cd "$ROOT_DIR/dist" && /usr/bin/shasum -a 256 "$(basename "$ARCHIVE")" > SHA256SUMS.txt)
/usr/bin/file "$ROOT_DIR/dist/TryFolder.app/Contents/MacOS/TryFolder"
printf 'Local archive prepared: %s\nNot notarized; do not label as a signed public release.\n' "$ARCHIVE"
