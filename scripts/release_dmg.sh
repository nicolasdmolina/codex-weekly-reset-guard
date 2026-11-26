#!/bin/bash
set -euo pipefail

# Build the public app download: a universal Second Wind.app signed with Developer
# ID and the hardened runtime, notarized and stapled, inside a signed, notarized
# and stapled disk image with SHA256SUMS. There is no unsigned fallback: without
# a Developer ID identity and notary credentials this script stops before building.
#
# Environment (values are never printed):
#   SECOND_WIND_TEAM_ID            Apple Developer team ID (required)
#   SECOND_WIND_KEYCHAIN           keychain holding the identity (optional)
#   SECOND_WIND_NOTARY_PROFILE     notarytool keychain profile, or all three of
#   SECOND_WIND_NOTARY_KEY_PATH    App Store Connect API key (.p8)
#   SECOND_WIND_NOTARY_KEY_ID
#   SECOND_WIND_NOTARY_ISSUER

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Second Wind"
DEVELOPER_ID_REQUIREMENT='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]'

usage() {
  printf 'Usage: %s --tag vX.Y.Z\n' "$0"
}

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 2 || "$1" != --tag || ! "$2" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  usage >&2
  exit 2
fi
TAG="$2"
VERSION="${BASH_REMATCH[1]}"
DMG_NAME="Second-Wind-$VERSION.dmg"
[[ "$(uname -s)" == Darwin ]] || fail 'Release builds require macOS.'

PLIST_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$PROJECT_ROOT/Resources/Info.plist")"
[[ "$PLIST_VERSION" == "$VERSION" ]] \
  || fail "Tag $TAG does not match Resources/Info.plist version $PLIST_VERSION."

TEAM_ID="${SECOND_WIND_TEAM_ID:-}"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail 'Set SECOND_WIND_TEAM_ID to the ten-character Apple team ID.'
KEYCHAIN="${SECOND_WIND_KEYCHAIN:-}"
[[ -z "$KEYCHAIN" || -f "$KEYCHAIN" ]] || fail 'SECOND_WIND_KEYCHAIN does not name a keychain file.'

NOTARY_AUTH=()
if [[ -n "${SECOND_WIND_NOTARY_PROFILE:-}" ]]; then
  if [[ -n "${SECOND_WIND_NOTARY_KEY_PATH:-}${SECOND_WIND_NOTARY_KEY_ID:-}${SECOND_WIND_NOTARY_ISSUER:-}" ]]; then
    fail 'Configure either SECOND_WIND_NOTARY_PROFILE or an API key, not both.'
  fi
  NOTARY_AUTH=(--keychain-profile "$SECOND_WIND_NOTARY_PROFILE")
elif [[ -n "${SECOND_WIND_NOTARY_KEY_PATH:-}" && -n "${SECOND_WIND_NOTARY_KEY_ID:-}" && -n "${SECOND_WIND_NOTARY_ISSUER:-}" ]]; then
  [[ -f "$SECOND_WIND_NOTARY_KEY_PATH" ]] || fail 'SECOND_WIND_NOTARY_KEY_PATH does not name a file.'
  NOTARY_AUTH=(--key "$SECOND_WIND_NOTARY_KEY_PATH" --key-id "$SECOND_WIND_NOTARY_KEY_ID"
    --issuer "$SECOND_WIND_NOTARY_ISSUER")
else
  fail 'Configure notarization: SECOND_WIND_NOTARY_PROFILE, or SECOND_WIND_NOTARY_KEY_PATH, _KEY_ID and _ISSUER.'
fi

FIND_IDENTITY=(security find-identity -v -p codesigning)
if [[ -n "$KEYCHAIN" ]]; then FIND_IDENTITY+=("$KEYCHAIN"); fi
IDENTITIES="$("${FIND_IDENTITY[@]}" 2>/dev/null || true)"
MATCHES="$(grep -E "^[[:space:]]*[0-9]+\) [0-9A-F]{40} \"Developer ID Application: .+ \($TEAM_ID\)\"\$" <<<"$IDENTITIES" || true)"
MATCH_COUNT="$(grep -c . <<<"$MATCHES" || true)"
[[ "$MATCH_COUNT" -eq 1 ]] \
  || fail "Expected one valid Developer ID Application identity for team $TEAM_ID; found $MATCH_COUNT."
IDENTITY="$(awk '{ print $2 }' <<<"$MATCHES")"
printf 'Signing with %s\n' "$(sed -E 's/^[^"]*"(.*)"$/\1/' <<<"$MATCHES")" >&2
REQUIREMENT="$DEVELOPER_ID_REQUIREMENT and certificate leaf[subject.OU] = \"$TEAM_ID\""

OUTPUT_DIRECTORY="$PROJECT_ROOT/dist/release/$TAG"
[[ ! -e "$OUTPUT_DIRECTORY/$DMG_NAME" ]] || fail "$OUTPUT_DIRECTORY/$DMG_NAME already exists. Move it aside to rebuild."
mkdir -p "$PROJECT_ROOT/dist/release"
STAGE="$(mktemp -d "$PROJECT_ROOT/dist/release/.stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# Retry briefly: stapling can trail acceptance, and hdiutil can hit "Resource busy" on CI.
retry() {
  local attempt
  for attempt in 1 2 3 4; do
    if "$@"; then return 0; fi
    [[ "$attempt" -lt 4 ]] && sleep $((attempt * 15))
  done
  return 1
}

notarize() {
  local file="$1" result="$STAGE/notary-$(basename "$1").json" status submission
  printf 'Submitting %s for notarization...\n' "$(basename "$file")" >&2
  xcrun notarytool submit "$file" "${NOTARY_AUTH[@]}" --wait --timeout 1h --output-format json > "$result" || true
  status="$(plutil -extract status raw -o - "$result" 2>/dev/null || true)"
  submission="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
  if [[ "$status" != Accepted ]]; then
    printf 'Notarization of %s ended with status: %s\n' "$(basename "$file")" "${status:-unknown}" >&2
    if [[ "$submission" =~ ^[0-9a-fA-F-]{36}$ ]]; then
      xcrun notarytool log "$submission" "${NOTARY_AUTH[@]}" >&2 || true
    fi
    return 1
  fi
  printf 'Notarization accepted (%s).\n' "$submission" >&2
}

staple() {
  xcrun stapler staple "$1" >&2 && xcrun stapler validate "$1" >&2
}

create_image() {
  rm -f "$STAGE/$DMG_NAME"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE/image" -fs HFS+ -format UDZO \
    -imagekey zlib-level=9 -ov "$STAGE/$DMG_NAME" -quiet
}

PACKAGE_FLAGS=(--universal --sign-identity "$IDENTITY")
if [[ -n "$KEYCHAIN" ]]; then PACKAGE_FLAGS+=(--keychain "$KEYCHAIN"); fi
"$PROJECT_ROOT/scripts/package_app.sh" "${PACKAGE_FLAGS[@]}" >/dev/null
APP="$STAGE/$APP_NAME.app"
ditto "$PROJECT_ROOT/dist/$APP_NAME.app" "$APP"
[[ "$(lipo -archs "$APP/Contents/MacOS/SecondWind" | tr ' ' '\n' | sort | tr '\n' ' ')" == 'arm64 x86_64 ' ]] \
  || fail 'The release build is not universal (arm64 and x86_64).'
codesign --verify --deep --strict -R "=$REQUIREMENT" "$APP" \
  || fail "The app is not signed with Developer ID for team $TEAM_ID."

ditto -c -k --keepParent "$APP" "$STAGE/notarize-app.zip"
notarize "$STAGE/notarize-app.zip" || fail 'Apple did not accept the app for notarization.'
retry staple "$APP" || fail 'Could not staple the notarization ticket to the app.'

mkdir "$STAGE/image"
ditto "$APP" "$STAGE/image/$APP_NAME.app"
ln -s /Applications "$STAGE/image/Applications"
retry create_image || fail 'Could not create the disk image.'
SIGN_FLAGS=(--force --timestamp --sign "$IDENTITY")
if [[ -n "$KEYCHAIN" ]]; then SIGN_FLAGS+=(--keychain "$KEYCHAIN"); fi
codesign "${SIGN_FLAGS[@]}" "$STAGE/$DMG_NAME"
notarize "$STAGE/$DMG_NAME" || fail 'Apple did not accept the disk image for notarization.'
retry staple "$STAGE/$DMG_NAME" || fail 'Could not staple the notarization ticket to the disk image.'

# The image is final once stapled; hash it now and never modify it afterward.
(cd "$STAGE" && shasum -a 256 "$DMG_NAME") > "$STAGE/SHA256SUMS"
"$PROJECT_ROOT/scripts/verify_release.sh" --tag "$TAG" --dir "$STAGE" --team-id "$TEAM_ID" --skip-provenance >&2

mkdir -p "$OUTPUT_DIRECTORY"
SUMS="$OUTPUT_DIRECTORY/SHA256SUMS"
{ if [[ -f "$SUMS" ]]; then grep -vF "  $DMG_NAME" "$SUMS" || true; fi; cat "$STAGE/SHA256SUMS"; } > "$STAGE/SHA256SUMS.next"
mv "$STAGE/$DMG_NAME" "$OUTPUT_DIRECTORY/$DMG_NAME"
mv "$STAGE/SHA256SUMS.next" "$SUMS"
printf '%s\n' "$OUTPUT_DIRECTORY/$DMG_NAME"
