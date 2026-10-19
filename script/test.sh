#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.cache/swift"
export TRYFOLDER_TEST_ROOT="$ROOT_DIR/Artifacts/TestRuns"
export TRYFOLDER_COORDINATION_ROOT="$ROOT_DIR/Artifacts/Coordination"
mkdir -p "$TRYFOLDER_TEST_ROOT"
swift test --scratch-path "$ROOT_DIR/.build" --cache-path "$ROOT_DIR/.cache/swiftpm" "$@"
