#!/bin/bash
set -euo pipefail

# Compile the same committed sources customers can download. Working-tree changes,
# account state and outputs from an earlier build never enter the app archive.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -ne 2 || "$1" != --tag || ! "$2" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  printf 'Usage: %s --tag vX.Y.Z\n' "$0" >&2
  exit 2
fi
TAG="$2"
VERSION="${BASH_REMATCH[1]}"
OUTPUT="$ROOT/dist/release/$TAG"
if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
  printf 'Release directory already exists: %s\n' "$OUTPUT" >&2
  exit 1
fi
mkdir -p "$ROOT/dist/release"
WORK="$(mktemp -d "$ROOT/dist/release/.build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ASSETS="$WORK/assets"
SOURCE="$("$ROOT/scripts/package_source.sh" --tag "$TAG" --output-dir "$ASSETS")"
unzip -q "$SOURCE" -d "$WORK"
APP="$("$WORK/Second-Wind-$VERSION/scripts/package_app.sh" --universal)"
APP_FILE="Second-Wind-$VERSION-mac.zip"
(cd "$(dirname "$APP")" && /usr/bin/zip -q -r "$ASSETS/$APP_FILE" 'Second Wind.app')
(cd "$ASSETS" && shasum -a 256 "$APP_FILE" >> SHA256SUMS)
COMMIT="$(git -C "$ROOT" rev-parse "refs/tags/$TAG^{commit}")"
"$ROOT/scripts/verify_release.sh" --tag "$TAG" --dir "$ASSETS" --source-commit "$COMMIT" \
  --skip-provenance --self-test >&2

# A concurrent build must not move its files into another build's release directory.
python3 -I -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$ASSETS" "$OUTPUT"
printf '%s\n' "$OUTPUT"
