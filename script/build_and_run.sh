#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
case "$MODE" in run|--verify|--debug|--logs|--telemetry|--demo) ;; *) echo 'Usage: script/build_and_run.sh [--verify|--debug|--logs|--telemetry|--demo]' >&2; exit 2;; esac
# Graceful termination lets journalled filesystem work settle when possible.
/usr/bin/pkill -TERM -x TryFolder >/dev/null 2>&1 || true
"$ROOT_DIR/script/build.sh" debug
APP="$ROOT_DIR/dist/TryFolder.app"
case "$MODE" in
  --debug) lldb -- "$APP/Contents/MacOS/TryFolder" ;;
  --demo) mkdir -p "$ROOT_DIR/LocalData/Sessions"; /usr/bin/open -n "$APP" --args --store "$ROOT_DIR/LocalData/Sessions" ;;
  --logs|--telemetry) /usr/bin/open -n "$APP"; /usr/bin/log stream --info --style compact --predicate 'process == "TryFolder"' ;;
  --verify) /usr/bin/open -n "$APP"; sleep 1; /usr/bin/pgrep -x TryFolder >/dev/null; echo 'TryFolder process is running.' ;;
  *) /usr/bin/open -n "$APP" ;;
esac
