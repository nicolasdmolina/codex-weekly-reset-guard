#!/bin/bash
set -euo pipefail

# Independently verify Second Wind release assets. Every listed asset must match
# SHA256SUMS and carry GitHub build provenance from the release workflow, pinned
# to the commit the public tag points to; the source archive must also name that
# commit. The app disk image must also be Developer ID signed with hardened runtime,
# notarized, stapled and accepted by Gatekeeper. Nothing is installed; the only
# write outside a temporary directory is the optional website manifest, written
# after every check has passed.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPOSITORY="nicolasdmolina/codex-weekly-reset-guard"
APP_NAME="Second Wind"
BUNDLE_ID="com.nickymolina.second-wind"
EXECUTABLE="SecondWind"
SITE_MANIFEST="$PROJECT_ROOT/site/src/release.json"
SUM_LINE='^([0-9a-f]{64})  (.+)$'
# Apple's Developer ID requirement: Apple-anchored chain, Developer ID intermediate,
# Developer ID Application leaf, and the expected team.
DEVELOPER_ID_REQUIREMENT='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]'
DANGEROUS_ENTITLEMENTS=(
  com.apple.security.get-task-allow
  com.apple.security.cs.debugger
  com.apple.security.cs.disable-library-validation
  com.apple.security.cs.allow-dyld-environment-variables
  com.apple.security.cs.allow-unsigned-executable-memory
  com.apple.security.cs.disable-executable-page-protection
  com.apple.security.cs.allow-jit
)

usage() {
  cat <<'EOF'
Usage:
  verify_release.sh --tag vX.Y.Z --published [--team-id TEAMID] [--self-test] [--write-site-manifest]
  verify_release.sh --tag vX.Y.Z --dir DIRECTORY [--team-id TEAMID] [--source-commit SHA] [--self-test]
                    [--skip-provenance]

--published downloads SHA256SUMS and every file it lists from the public GitHub
release without signing in. --dir checks files already on disk. --team-id is
required when the release includes the app disk image. Provenance checks need
the GitHub CLI signed in (gh auth login). The expected source commit is read
from the public tag with git ls-remote; --source-commit must agree with it.
--skip-provenance skips GitHub checks and pins the commit only if --source-commit
is given. --repo OWNER/NAME checks a fork.
EOF
}

TAG=""
DIRECTORY=""
PUBLISHED=false
TEAM_ID=""
SOURCE_COMMIT=""
SELF_TEST=false
SKIP_PROVENANCE=false
WRITE_MANIFEST=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag|--dir|--team-id|--repo|--source-commit)
      if [[ $# -lt 2 ]]; then usage >&2; exit 2; fi
      case "$1" in
        --tag) TAG="$2" ;;
        --dir) DIRECTORY="$2" ;;
        --team-id) TEAM_ID="$2" ;;
        --repo) REPOSITORY="$2" ;;
        --source-commit) SOURCE_COMMIT="$2" ;;
      esac
      shift 2
      ;;
    --published) PUBLISHED=true; shift ;;
    --self-test) SELF_TEST=true; shift ;;
    --skip-provenance) SKIP_PROVENANCE=true; shift ;;
    --write-site-manifest) WRITE_MANIFEST=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

fail() {
  printf 'FAIL  %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok    %s\n' "$*" >&2
}

[[ "$TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || { usage >&2; exit 2; }
VERSION="${BASH_REMATCH[1]}"
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'the repository must look like owner/name'
[[ -z "$TEAM_ID" || "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail 'a team ID is ten capital letters or digits'
[[ -z "$SOURCE_COMMIT" || "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail 'a source commit is 40 lowercase hexadecimal characters'
if [[ "$PUBLISHED" == true && -n "$DIRECTORY" ]] || [[ "$PUBLISHED" == false && -z "$DIRECTORY" ]]; then
  usage >&2
  exit 2
fi
if [[ "$WRITE_MANIFEST" == true && ( "$PUBLISHED" != true || "$SKIP_PROVENANCE" == true ) ]]; then
  fail '--write-site-manifest needs --published and full provenance checks'
fi

SOURCE_FILE="Second-Wind-$VERSION-source.zip"
SOURCE_FOLDER="Second-Wind-$VERSION"
APP_FILE="Second-Wind-$VERSION.dmg"
RELEASE_URL="https://github.com/$REPOSITORY/releases/download/$TAG"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/second-wind-verify.XXXXXX")"
MOUNT="$WORK/mount"
MOUNTED=false
cleanup() {
  if [[ "$MOUNTED" == true ]]; then
    if ! hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 && ! hdiutil detach "$MOUNT" -force -quiet >/dev/null 2>&1; then
      printf 'Could not detach %s. Eject it in Finder.\n' "$MOUNT" >&2
      return
    fi
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

if [[ "$PUBLISHED" == true ]]; then
  DIRECTORY="$WORK/download"
  mkdir -p "$DIRECTORY"
fi
[[ -d "$DIRECTORY" ]] || fail "no such directory: $DIRECTORY"

download() {
  # Anonymous HTTPS only: success shows the asset is public, not merely visible to a signed-in maintainer.
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --tlsv1.2 --retry 3 --output "$DIRECTORY/$1" "$RELEASE_URL/$1" \
    || fail "could not download $1 from the public $TAG release"
}

sha256_of() {
  shasum -a 256 "$1" | awk '{ print $1 }'
}

check_digest() {
  [[ -f "$DIRECTORY/$1" && ! -L "$DIRECTORY/$1" ]] || fail "$1 is listed in SHA256SUMS but missing"
  [[ "$(sha256_of "$DIRECTORY/$1")" == "$2" ]] || fail "$1 does not match its SHA-256 in SHA256SUMS"
  pass "$1 matches SHA-256 $2"
}

# The commit the public tag points to, peeled through an annotated tag.
resolve_tag_commit() {
  local listing direct peeled
  listing="$(git ls-remote --tags "https://github.com/$REPOSITORY.git" "refs/tags/$TAG" "refs/tags/$TAG^{}" 2>/dev/null)" \
    || fail "could not read tag $TAG from github.com/$REPOSITORY"
  direct="$(awk -v ref="refs/tags/$TAG" '$2 == ref { print $1 }' <<<"$listing")"
  peeled="$(awk -v ref="refs/tags/$TAG^{}" '$2 == ref { print $1 }' <<<"$listing")"
  EXPECTED_COMMIT="${peeled:-$direct}"
  [[ "$EXPECTED_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "$TAG is not a public tag of $REPOSITORY"
  if [[ -n "$SOURCE_COMMIT" && "$SOURCE_COMMIT" != "$EXPECTED_COMMIT" ]]; then
    fail "the public $TAG tag points to $EXPECTED_COMMIT, not $SOURCE_COMMIT"
  fi
  pass "public tag $TAG points to commit $EXPECTED_COMMIT"
}

check_provenance() {
  if [[ "$SKIP_PROVENANCE" == true ]]; then
    printf 'SKIP  GitHub provenance for %s was not checked (--skip-provenance)\n' "$1" >&2
    return
  fi
  command -v gh >/dev/null || fail 'provenance checks need the GitHub CLI (gh), signed in with gh auth login'
  if ! gh attestation verify "$DIRECTORY/$1" --repo "$REPOSITORY" \
      --signer-workflow "$REPOSITORY/.github/workflows/release.yml" \
      --source-ref "refs/tags/$TAG" --source-digest "$EXPECTED_COMMIT" \
      --deny-self-hosted-runners > "$WORK/attestation.log" 2>&1; then
    sed -n '1,20p' "$WORK/attestation.log" >&2
    fail "$1 has no GitHub build provenance from release.yml at $TAG, commit $EXPECTED_COMMIT"
  fi
  pass "$1 was built by $REPOSITORY release.yml from $TAG at commit $EXPECTED_COMMIT on a GitHub-hosted runner"
}

plist_value() {
  plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

check_release_plist() {
  local plist="$1" label="$2" marker
  plutil -lint "$plist" >/dev/null 2>&1 || fail "$label has an invalid Info.plist"
  [[ "$(plist_value "$plist" CFBundleIdentifier)" == "$BUNDLE_ID" ]] || fail "$label has the wrong bundle identifier"
  [[ "$(plist_value "$plist" CFBundleShortVersionString)" == "$VERSION" ]] || fail "$label is not version $VERSION"
  for marker in GuardPreviewKind GuardDiagnosticSupportDirectory; do
    if plutil -extract "$marker" raw -o - "$plist" >/dev/null 2>&1; then
      fail "$label contains the QA-only marker $marker"
    fi
  done
}

check_gatekeeper() {
  local type="$1" target="$2" label="$3" output
  if [[ "$type" == open ]]; then
    output="$(spctl --assess --type open --context context:primary-signature -vv "$target" 2>&1)" \
      || fail "Gatekeeper rejects $label"
  else
    output="$(spctl --assess --type execute -vv "$target" 2>&1)" || fail "Gatekeeper rejects $label"
  fi
  grep -qx 'source=Notarized Developer ID' <<<"$output" || fail "Gatekeeper does not report $label as notarized Developer ID"
  pass "Gatekeeper accepts $label as notarized Developer ID"
}

check_stapled() {
  local output
  output="$(xcrun stapler validate "$1" 2>&1)" || fail "$2 has no valid stapled notarization ticket"
  grep -q 'The validate action worked!' <<<"$output" || fail "$2 has no valid stapled notarization ticket"
  pass "$2 has a stapled notarization ticket"
}

verify_source() {
  local zip="$DIRECTORY/$SOURCE_FILE" listing entry required details
  check_digest "$SOURCE_FILE" "$1"
  listing="$(unzip -Z1 "$zip" 2>/dev/null)" || fail "$SOURCE_FILE is not a readable ZIP archive"
  while IFS= read -r entry; do
    [[ "$entry" == "$SOURCE_FOLDER/"* ]] || fail "$SOURCE_FILE has an entry outside $SOURCE_FOLDER/"
    case "/$entry/" in
      */../*|*/./*) fail "$SOURCE_FILE has a path that leaves its folder" ;;
    esac
  done <<<"$listing"
  for required in Package.swift Resources/Info.plist scripts/install_app.sh scripts/package_app.sh LICENSE; do
    grep -qxF "$SOURCE_FOLDER/$required" <<<"$listing" || fail "$SOURCE_FILE is missing $required"
  done
  details="$(unzip -Z "$zip" 2>/dev/null)" || fail "$SOURCE_FILE cannot be listed"
  if grep -q '^l' <<<"$details"; then
    fail "$SOURCE_FILE contains a symbolic link"
  fi
  for required in install_app.sh package_app.sh; do
    grep -Eq "^-rwx.* $SOURCE_FOLDER/scripts/$required\$" <<<"$details" \
      || fail "$SOURCE_FILE does not keep scripts/$required executable"
  done
  unzip -p "$zip" "$SOURCE_FOLDER/Resources/Info.plist" > "$WORK/source-Info.plist" 2>/dev/null \
    || fail "$SOURCE_FILE has no readable Info.plist"
  check_release_plist "$WORK/source-Info.plist" "$SOURCE_FILE"
  pass "$SOURCE_FILE unpacks to $SOURCE_FOLDER/ with version $VERSION and executable install scripts"
  if [[ -n "$EXPECTED_COMMIT" ]]; then
    # git archive records the archived commit as the ZIP comment.
    [[ "$(unzip -zq "$zip" 2>/dev/null | tr -d '[:space:]')" == "$EXPECTED_COMMIT" ]] \
      || fail "$SOURCE_FILE was not archived from commit $EXPECTED_COMMIT"
    pass "$SOURCE_FILE was archived from commit $EXPECTED_COMMIT"
  else
    printf 'SKIP  the source commit of %s was not checked (no --source-commit)\n' "$SOURCE_FILE" >&2
  fi
  check_provenance "$SOURCE_FILE"
}

APP_ARCHITECTURES=""
APP_MINIMUM_SYSTEM=""

verify_app() {
  local dmg="$DIRECTORY/$APP_FILE" app="$MOUNT/$APP_NAME.app" requirement details entitlements key entries archs
  [[ "$(uname -s)" == Darwin ]] || fail 'checking the app disk image needs macOS'
  [[ -n "$TEAM_ID" ]] || fail "$APP_FILE is listed, so pass the expected Apple team with --team-id"
  requirement="$DEVELOPER_ID_REQUIREMENT and certificate leaf[subject.OU] = \"$TEAM_ID\""
  check_digest "$APP_FILE" "$1"
  [[ "$(spctl --status 2>&1)" == 'assessments enabled' ]] || fail 'Gatekeeper assessments are disabled on this Mac, so they prove nothing'

  codesign --verify --strict --verbose=2 "$dmg" >/dev/null 2>&1 || fail "$APP_FILE has an invalid code signature"
  codesign --verify --strict -R "=$requirement" "$dmg" >/dev/null 2>&1 \
    || fail "$APP_FILE is not signed with a Developer ID Application certificate for team $TEAM_ID"
  pass "$APP_FILE is signed with Developer ID for team $TEAM_ID"
  check_stapled "$dmg" "$APP_FILE"
  check_gatekeeper open "$dmg" "$APP_FILE"

  mkdir "$MOUNT"
  hdiutil attach "$dmg" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" -quiet >/dev/null 2>&1 \
    || fail "$APP_FILE could not be mounted read-only"
  MOUNTED=true
  entries="$(cd "$MOUNT" && ls -A)"
  [[ "$entries" == "$(printf 'Applications\n%s.app' "$APP_NAME")" ]] \
    || fail "$APP_FILE should hold only $APP_NAME.app and an Applications shortcut"
  [[ -L "$MOUNT/Applications" && "$(readlink "$MOUNT/Applications")" == /Applications ]] \
    || fail "the Applications shortcut in $APP_FILE does not point to /Applications"
  [[ -d "$app" && ! -L "$app" ]] || fail "$APP_NAME.app in $APP_FILE is not a real app bundle"
  pass "$APP_FILE holds $APP_NAME.app and an Applications shortcut"

  codesign --verify --deep --strict --verbose=2 "$app" >/dev/null 2>&1 || fail "$APP_NAME.app has an invalid code signature"
  codesign --verify --strict -R "=$requirement and identifier \"$BUNDLE_ID\"" "$app" >/dev/null 2>&1 \
    || fail "$APP_NAME.app is not signed as $BUNDLE_ID with Developer ID for team $TEAM_ID"
  details="$(codesign -dv --verbose=4 "$app" 2>&1)" || fail "$APP_NAME.app signature details are unreadable"
  grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)' <<<"$details" \
    || fail "$APP_NAME.app is not signed with the hardened runtime"
  grep -q '^Timestamp=' <<<"$details" || fail "$APP_NAME.app has no secure signing timestamp"
  ! grep -q '^Signature=adhoc' <<<"$details" || fail "$APP_NAME.app is ad-hoc signed"
  entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)"
  for key in "${DANGEROUS_ENTITLEMENTS[@]}"; do
    if grep -qF "<key>$key</key>" <<<"$entitlements"; then
      fail "$APP_NAME.app requests the $key entitlement"
    fi
  done
  pass "$APP_NAME.app is signed as $BUNDLE_ID with hardened runtime, a secure timestamp and no debugging entitlements"
  check_stapled "$app" "$APP_NAME.app"
  check_gatekeeper execute "$app" "$APP_NAME.app"

  check_release_plist "$app/Contents/Info.plist" "$APP_NAME.app"
  [[ "$(plist_value "$app/Contents/Info.plist" CFBundleExecutable)" == "$EXECUTABLE" ]] \
    || fail "$APP_NAME.app names the wrong executable"
  APP_MINIMUM_SYSTEM="$(plist_value "$app/Contents/Info.plist" LSMinimumSystemVersion)"
  [[ "$APP_MINIMUM_SYSTEM" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "$APP_NAME.app has no minimum macOS version"
  archs="$(lipo -archs "$app/Contents/MacOS/$EXECUTABLE" 2>/dev/null)" || fail "$APP_NAME.app has no readable executable"
  archs="$(tr ' ' '\n' <<<"$archs" | sort | tr '\n' ' ')"
  [[ "$archs" == 'arm64 x86_64 ' ]] || fail "$APP_NAME.app is not universal (found: ${archs% })"
  APP_ARCHITECTURES='"arm64", "x86_64"'
  pass "$APP_NAME.app $VERSION is universal (arm64, x86_64) for macOS $APP_MINIMUM_SYSTEM or later"

  if [[ "$SELF_TEST" == true ]]; then
    run_self_test "$app"
  fi
  check_provenance "$APP_FILE"
}

run_self_test() {
  local copy="$WORK/installed/$APP_NAME.app" binary
  mkdir -p "$WORK/installed"
  ditto "$1" "$copy"
  xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");Safari;" "$copy"
  check_gatekeeper execute "$copy" "a quarantined copy of $APP_NAME.app"
  binary="$copy/Contents/MacOS/$EXECUTABLE"
  "$binary" --self-test >/dev/null 2>&1 || fail "$APP_NAME.app failed its self-test on $(uname -m)"
  pass "$APP_NAME.app passed its self-test on $(uname -m)"
  if [[ "$(uname -m)" == arm64 ]]; then
    if arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
      arch -x86_64 "$binary" --self-test >/dev/null 2>&1 || fail "$APP_NAME.app failed its self-test on x86_64"
      pass "$APP_NAME.app passed its self-test on x86_64 (Rosetta)"
    else
      printf 'SKIP  x86_64 self-test: Rosetta is not installed on this Mac\n' >&2
    fi
  else
    printf 'SKIP  arm64 self-test: this Mac cannot run arm64 code\n' >&2
  fi
}

write_site_manifest() {
  local temporary="$SITE_MANIFEST.tmp.$$"
  {
    printf '{\n  "release": {\n'
    printf '    "repository": "%s",\n    "tag": "%s",\n' "$REPOSITORY" "$TAG"
    printf '    "source": {\n      "file": "%s",\n      "folder": "%s",\n      "sha256": "%s"\n    },\n' \
      "$SOURCE_FILE" "$SOURCE_FOLDER" "$SOURCE_SHA"
    if [[ -n "$APP_SHA" ]]; then
      printf '    "app": {\n      "file": "%s",\n      "sha256": "%s",\n' "$APP_FILE" "$APP_SHA"
      printf '      "architectures": [%s],\n      "minimumSystemVersion": "%s",\n      "teamId": "%s"\n    }\n' \
        "$APP_ARCHITECTURES" "$APP_MINIMUM_SYSTEM" "$TEAM_ID"
    else
      printf '    "app": null\n'
    fi
    printf '  }\n}\n'
  } > "$temporary"
  mv "$temporary" "$SITE_MANIFEST"
  printf 'Wrote %s\n' "$SITE_MANIFEST" >&2
}

EXPECTED_COMMIT=""
if [[ "$SKIP_PROVENANCE" == false ]]; then
  resolve_tag_commit
elif [[ -n "$SOURCE_COMMIT" ]]; then
  EXPECTED_COMMIT="$SOURCE_COMMIT"
fi
if [[ "$PUBLISHED" == true ]]; then
  download SHA256SUMS
fi
[[ -f "$DIRECTORY/SHA256SUMS" && ! -L "$DIRECTORY/SHA256SUMS" ]] || fail 'SHA256SUMS is missing'

SOURCE_SHA=""
APP_SHA=""
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "$line" ]] || continue
  [[ "$line" =~ $SUM_LINE ]] || fail 'SHA256SUMS has a malformed line'
  case "${BASH_REMATCH[2]}" in
    "$SOURCE_FILE")
      [[ -z "$SOURCE_SHA" ]] || fail "SHA256SUMS lists $SOURCE_FILE twice"
      SOURCE_SHA="${BASH_REMATCH[1]}"
      ;;
    "$APP_FILE")
      [[ -z "$APP_SHA" ]] || fail "SHA256SUMS lists $APP_FILE twice"
      APP_SHA="${BASH_REMATCH[1]}"
      ;;
    *) fail "SHA256SUMS lists a file that is not part of the $TAG release" ;;
  esac
done < "$DIRECTORY/SHA256SUMS"
[[ -n "$SOURCE_SHA" || -n "$APP_SHA" ]] || fail 'SHA256SUMS lists no release files'
if [[ "$WRITE_MANIFEST" == true && -z "$SOURCE_SHA" ]]; then
  fail "the website needs $SOURCE_FILE in the release"
fi

if [[ -n "$SOURCE_SHA" ]]; then
  [[ "$PUBLISHED" == false ]] || download "$SOURCE_FILE"
  verify_source "$SOURCE_SHA"
fi
if [[ -n "$APP_SHA" ]]; then
  [[ "$PUBLISHED" == false ]] || download "$APP_FILE"
  verify_app "$APP_SHA"
fi

if [[ "$WRITE_MANIFEST" == true ]]; then
  write_site_manifest
fi
if [[ -n "$SOURCE_SHA" && -n "$APP_SHA" ]]; then
  SUMMARY="Verified Second Wind $TAG: source, notarized universal app"
elif [[ -n "$SOURCE_SHA" ]]; then
  SUMMARY="Verified Second Wind $TAG: source"
else
  SUMMARY="Verified Second Wind $TAG: notarized universal app"
fi
[[ -z "$EXPECTED_COMMIT" ]] || SUMMARY="$SUMMARY from commit $EXPECTED_COMMIT"
[[ "$SKIP_PROVENANCE" == false ]] || SUMMARY="$SUMMARY (provenance NOT checked)"
printf '%s\n' "$SUMMARY"
