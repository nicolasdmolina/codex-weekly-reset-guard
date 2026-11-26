#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Second Wind"
APP_PATH="$PROJECT_ROOT/dist/$APP_NAME.app"
BUILD_FLAGS=(-c release)
SIGN_IDENTITY=""
KEYCHAIN=""

usage() {
    printf 'Usage: %s [--universal] [--sign-identity SHA1 [--keychain PATH]]\n' "$0"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --universal) BUILD_FLAGS+=(--arch arm64 --arch x86_64); shift ;;
        --sign-identity|--keychain)
            if [[ $# -lt 2 || -z "$2" ]]; then
                usage >&2
                exit 2
            fi
            if [[ "$1" == --sign-identity ]]; then SIGN_IDENTITY="$2"; else KEYCHAIN="$2"; fi
            shift 2
            ;;
        *) usage >&2; exit 2 ;;
    esac
done
if [[ -n "$KEYCHAIN" && -z "$SIGN_IDENTITY" ]]; then
    usage >&2
    exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
    printf 'Packaging requires macOS 14 or newer and Swift 6.\n' >&2
    exit 1
fi

cd "$PROJECT_ROOT"
swift build "${BUILD_FLAGS[@]}" -Xswiftc -warnings-as-errors >&2
BIN_PATH="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
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
cp "$BIN_PATH/SecondWind" "$STAGED_APP/Contents/MacOS/SecondWind"
cp "$PROJECT_ROOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$PROJECT_ROOT/LICENSE" "$STAGED_APP/Contents/Resources/LICENSE"
cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"

if [[ -n "$SIGN_IDENTITY" ]]; then
    # Release signing: hardened runtime and a secure timestamp, both required for notarization.
    SIGN_FLAGS=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
    if [[ -n "$KEYCHAIN" ]]; then SIGN_FLAGS+=(--keychain "$KEYCHAIN"); fi
    codesign "${SIGN_FLAGS[@]}" "$STAGED_APP" >&2
    SIGNATURE_KIND="a signed, not yet notarized"
else
    # Ad-hoc signing checks bundle integrity only. It is not a public binary release.
    codesign --force --sign - --timestamp=none "$STAGED_APP" >&2
    SIGNATURE_KIND="an ad-hoc signed, unnotarized"
fi
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
printf 'Built %s app for %s.\n' "$SIGNATURE_KIND" "$(lipo -archs "$APP_PATH/Contents/MacOS/SecondWind" 2>/dev/null || uname -m)" >&2
printf '%s\n' "$APP_PATH"
