#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Codex Weekly Reset Guard"
APP_PATH="$PROJECT_ROOT/dist/$APP_NAME.app"

if [[ $# -ne 0 ]]; then
    printf 'Usage: %s\n' "$0" >&2
    exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
    printf 'Packaging requires macOS 14 or newer and Swift 6.\n' >&2
    exit 1
fi

cd "$PROJECT_ROOT"
swift build -c release -Xswiftc -warnings-as-errors >&2
BIN_PATH="$(swift build -c release --show-bin-path)"
plutil -lint "$PROJECT_ROOT/Resources/Info.plist" >&2
for QA_KEY in GuardPreviewKind GuardDiagnosticSupportDirectory; do
    if plutil -extract "$QA_KEY" raw -o - "$PROJECT_ROOT/Resources/Info.plist" >/dev/null 2>&1; then
        printf 'Release metadata contains a QA-only marker: %s\n' "$QA_KEY" >&2
        exit 1
    fi
done

mkdir -p "$PROJECT_ROOT/dist"
STAGING_DIRECTORY="$(mktemp -d "$PROJECT_ROOT/dist/.package.XXXXXX")"
trap 'rm -rf "$STAGING_DIRECTORY"' EXIT
STAGED_APP="$STAGING_DIRECTORY/$APP_NAME.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_PATH/CodexWeeklyResetGuard" "$STAGED_APP/Contents/MacOS/CodexWeeklyResetGuard"
cp "$PROJECT_ROOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$PROJECT_ROOT/LICENSE" "$STAGED_APP/Contents/Resources/LICENSE"

# This is a local, host-architecture build. Ad-hoc signing does not supply a
# Developer ID identity or notarization and is not a signed public binary release.
codesign --force --sign - --timestamp=none "$STAGED_APP" >&2
codesign --verify --deep --strict "$STAGED_APP" >&2

PREVIOUS_APP=""
if [[ -e "$APP_PATH" || -L "$APP_PATH" ]]; then
    mkdir -p "$PROJECT_ROOT/dist/previous-builds"
    BACKUP_DIRECTORY="$(mktemp -d "$PROJECT_ROOT/dist/previous-builds/build.XXXXXX")"
    PREVIOUS_APP="$BACKUP_DIRECTORY/$APP_NAME.app"
    mv "$APP_PATH" "$PREVIOUS_APP"
fi
if ! mv "$STAGED_APP" "$APP_PATH"; then
    if [[ -n "$PREVIOUS_APP" ]]; then
        mv "$PREVIOUS_APP" "$APP_PATH"
    fi
    exit 1
fi
printf 'Built an ad-hoc signed, unnotarized app for %s.\n' "$(uname -m)" >&2
printf '%s\n' "$APP_PATH"
