#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cd "$PROJECT_ROOT"

if [[ "$(uname -s)" != Darwin ]]; then
  printf 'Tests require macOS 14 or newer and Swift 6.\n' >&2
  exit 1
fi

# Some standalone Command Line Tools releases keep Swift Testing outside
# SwiftPM's runtime search paths. Full Xcode must use its own toolchain paths.
DEVELOPER_DIRECTORY="$(xcode-select --print-path)"
TEST_FRAMEWORKS="$DEVELOPER_DIRECTORY/Library/Developer/Frameworks"
TEST_LIBRARIES="$DEVELOPER_DIRECTORY/Library/Developer/usr/lib"
TEST_FLAGS=()
if [[ "$DEVELOPER_DIRECTORY" == */CommandLineTools && -d "$TEST_FRAMEWORKS/Testing.framework" ]]; then
  TEST_FLAGS=(
    -Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS"
    -Xlinker -F -Xlinker "$TEST_FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$TEST_LIBRARIES"
  )
fi

swift test ${TEST_FLAGS[@]+"${TEST_FLAGS[@]}"} "$@"
