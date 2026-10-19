#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ ! -d "$ROOT_DIR/dist/TryFolder.app" ]; then
  echo 'Build the app first with ./script/package.sh.' >&2
  exit 1
fi
/usr/bin/open -n "$ROOT_DIR/dist/TryFolder.app" --args --store "$ROOT_DIR/LocalData/Sessions"
