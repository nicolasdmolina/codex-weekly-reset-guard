#!/bin/bash
set -euo pipefail

# Archive the committed source at a release tag as Second-Wind-X.Y.Z-source.zip,
# unpacking to a Second-Wind-X.Y.Z folder, and record it in SHA256SUMS. Only the
# tagged commit is read, so local edits and untracked files never enter the archive.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ( $# -ne 2 && $# -ne 4 ) || "$1" != --tag || ! "$2" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  printf 'Usage: %s --tag vX.Y.Z [--output-dir /absolute/directory]\n' "$0" >&2
  exit 2
fi
TAG="$2"
VERSION="${BASH_REMATCH[1]}"
OUTPUT_DIRECTORY="$PROJECT_ROOT/dist/release/$TAG"
if [[ $# -eq 4 ]]; then
  [[ "$3" == --output-dir && "$4" == /* ]] || { printf 'Expected --output-dir /absolute/directory\n' >&2; exit 2; }
  OUTPUT_DIRECTORY="$4"
fi
FOLDER="Second-Wind-$VERSION"
ARCHIVE="$FOLDER-source.zip"

cd "$PROJECT_ROOT"
COMMIT="$(git rev-parse --verify --quiet "refs/tags/$TAG^{commit}")" || {
  printf 'Tag %s does not exist in this checkout.\n' "$TAG" >&2
  exit 1
}
PLIST_VERSION="$(git show "$COMMIT:Resources/Info.plist" \
  | python3 -I -c 'import plistlib, sys; print(plistlib.loads(sys.stdin.buffer.read())["CFBundleShortVersionString"])')"
if [[ "$PLIST_VERSION" != "$VERSION" ]]; then
  printf 'Tag %s does not match Resources/Info.plist version %s.\n' "$TAG" "$PLIST_VERSION" >&2
  exit 1
fi

if [[ -e "$OUTPUT_DIRECTORY/$ARCHIVE" ]]; then
  printf '%s already exists. Move it aside to rebuild.\n' "$OUTPUT_DIRECTORY/$ARCHIVE" >&2
  exit 1
fi
mkdir -p "$OUTPUT_DIRECTORY"
STAGE="$(mktemp -d "$OUTPUT_DIRECTORY/.stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

git archive --format=zip --prefix="$FOLDER/" --output="$STAGE/$ARCHIVE" "$COMMIT"
if command -v shasum >/dev/null; then
  (cd "$STAGE" && shasum -a 256 "$ARCHIVE") > "$STAGE/SHA256SUMS"
else
  (cd "$STAGE" && sha256sum "$ARCHIVE") > "$STAGE/SHA256SUMS"
fi

SUMS="$OUTPUT_DIRECTORY/SHA256SUMS"
{ if [[ -f "$SUMS" ]]; then grep -vF "  $ARCHIVE" "$SUMS" || true; fi; cat "$STAGE/SHA256SUMS"; } > "$STAGE/SHA256SUMS.next"
mv "$STAGE/$ARCHIVE" "$OUTPUT_DIRECTORY/$ARCHIVE"
mv "$STAGE/SHA256SUMS.next" "$SUMS"
printf 'Archived %s at %s.\n' "$TAG" "$COMMIT" >&2
printf '%s\n' "$OUTPUT_DIRECTORY/$ARCHIVE"
