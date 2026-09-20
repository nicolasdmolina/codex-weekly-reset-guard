#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="$PROJECT_ROOT/qa-artifacts"
SHOULD_RENDER_PREVIEWS=true

if [[ "${1:-}" == --skip-previews && $# -eq 1 ]]; then
  SHOULD_RENDER_PREVIEWS=false
elif [[ $# -ne 0 ]]; then
  printf 'Usage: %s [--skip-previews]\n' "$0" >&2
  exit 2
fi

cd "$PROJECT_ROOT"

"$PROJECT_ROOT/scripts/test_tooling.sh"
"$PROJECT_ROOT/scripts/test.sh"
swift build -Xswiftc -warnings-as-errors
DEBUG_BIN_PATH="$(swift build --show-bin-path)"
# These modes use synthetic fixtures; never substitute --doctor or a bare launch.
"$DEBUG_BIN_PATH/CodexWeeklyResetGuard" --self-test
if [[ "$SHOULD_RENDER_PREVIEWS" == true ]]; then
  mkdir -p "$ARTIFACTS"
  "$DEBUG_BIN_PATH/CodexWeeklyResetGuard" --render-all-previews "$ARTIFACTS"
  for preview in onboarding onboarding-error connect paused healthy near redeemed auth-error; do
    test -s "$ARTIFACTS/$preview.png"
  done
fi

"$PROJECT_ROOT/scripts/package_app.sh"
codesign --verify --deep --strict "$PROJECT_ROOT/dist/Codex Weekly Reset Guard.app"

printf 'Offline native release checks passed (previews: %s).\n' "$SHOULD_RENDER_PREVIEWS"
