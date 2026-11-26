#!/bin/bash
set -euo pipefail

# Verify the two downloadable archives against their tag, GitHub provenance and
# contents before updating the website. No Apple identity is needed.
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPOSITORY="nicolasdmolina/codex-weekly-reset-guard"
APP_NAME="Second Wind"
BUNDLE_ID="com.nickymolina.second-wind"
EXECUTABLE="SecondWind"
SITE_MANIFEST="$PROJECT_ROOT/site/src/release.json"
SUM_LINE='^([0-9a-f]{64})  (.+)$'

usage() {
  cat <<'EOF'
Usage:
  verify_release.sh --tag vX.Y.Z --published [--source-commit SHA] [--self-test] [--write-site-manifest]
  verify_release.sh --tag vX.Y.Z --dir DIRECTORY [--source-commit SHA] [--self-test] [--skip-provenance]

--published downloads the files over anonymous HTTPS. --dir checks local files.
The GitHub CLI verifies provenance against the public tag and its exact commit.
--self-test runs the checked app from a temporary folder on macOS.
--skip-provenance is for local builds and cannot write the website manifest.
EOF
}

TAG=""
DIRECTORY=""
PUBLISHED=false
SOURCE_COMMIT=""
SELF_TEST=false
SKIP_PROVENANCE=false
WRITE_MANIFEST=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag|--dir|--repo|--source-commit)
      if [[ $# -lt 2 ]]; then usage >&2; exit 2; fi
      case "$1" in
        --tag) TAG="$2" ;;
        --dir) DIRECTORY="$2" ;;
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
APP_FILE="Second-Wind-$VERSION-mac.zip"
RELEASE_URL="https://github.com/$REPOSITORY/releases/download/$TAG"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/second-wind-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

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

APP_MINIMUM_SYSTEM=""

verify_app() {
  local file="$DIRECTORY/$APP_FILE" app="$WORK/$APP_NAME.app" executable arch archs details entitlements target
  [[ "$(uname -s)" == Darwin ]] || fail 'checking the Mac app needs macOS'
  check_digest "$APP_FILE" "$1"
  # Authenticate public artifacts before extracting or running code from them.
  check_provenance "$APP_FILE"
  python3 -I "$PROJECT_ROOT/scripts/check_app_zip.py" "$file" || fail 'invalid app archive'
  ditto -x -k "$file" "$WORK" || fail 'could not unpack the Mac app'
  check_release_plist "$app/Contents/Info.plist" "$APP_NAME.app"
  [[ "$(plist_value "$app/Contents/Info.plist" CFBundleExecutable)" == "$EXECUTABLE" ]] || fail 'incorrect bundle executable'
  APP_MINIMUM_SYSTEM="$(plist_value "$app/Contents/Info.plist" LSMinimumSystemVersion)"
  [[ "$APP_MINIMUM_SYSTEM" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail 'invalid minimum macOS version'

  executable="$app/Contents/MacOS/$EXECUTABLE"
  archs="$(lipo -archs "$executable" | tr ' ' '\n' | sort | tr '\n' ' ')" || fail 'cannot read Mac executable architectures'
  [[ "$archs" == 'arm64 x86_64 ' ]] || fail "expected a universal Mac app (found: ${archs% })"
  codesign --verify --all-architectures --deep --strict "$app" || fail 'invalid app code signature'
  for arch in arm64 x86_64; do
    details="$(codesign -d --arch "$arch" --verbose=4 "$app" 2>&1)" || fail "unreadable $arch signature"
    grep -qxF "Identifier=$BUNDLE_ID" <<<"$details" || fail "incorrect $arch signing identifier"
    grep -qx 'Signature=adhoc' <<<"$details" || fail "expected an ad-hoc signature for $arch"
    grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)' <<<"$details" || fail "missing hardened runtime on $arch"
    entitlements="$(codesign -d --arch "$arch" --entitlements - --xml "$app" 2>/dev/null)" || fail "unreadable $arch entitlements"
    if [[ -n "$entitlements" ]]; then
      python3 -I -c 'import plistlib, sys; sys.exit(plistlib.load(sys.stdin.buffer) != {})' \
        <<<"$entitlements" || fail "unexpected entitlements on $arch"
    fi
    target="$(xcrun vtool -arch "$arch" -show-build "$executable" |
      awk '$1 == "platform" { platform = $2 } $1 == "minos" && platform == "MACOS" { print $2 }')"
    [[ "$target" == "$APP_MINIMUM_SYSTEM" ]] || fail "the $arch deployment target differs from the app metadata"
  done
  pass "$APP_NAME.app $VERSION has valid ad-hoc signatures for Apple silicon and Intel on macOS $APP_MINIMUM_SYSTEM or later"
  if [[ "$SELF_TEST" == true ]]; then
    "$executable" --self-test >&2 || fail 'the native app self-test failed'
    if [[ "$(uname -m)" == arm64 ]]; then
      if arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
        arch -x86_64 "$executable" --self-test >&2 || fail 'the Intel app self-test failed'
        pass 'both the Apple silicon and Intel app self-tests passed'
      else
        printf 'SKIP  Intel self-test: Rosetta is not installed on this Mac\n' >&2
      fi
    fi
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
      printf '      "architectures": ["arm64", "x86_64"],\n      "minimumSystemVersion": "%s",\n      "signing": "ad-hoc"\n    }\n' \
        "$APP_MINIMUM_SYSTEM"
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
[[ -n "$SOURCE_SHA" ]] || fail "the release needs $SOURCE_FILE"
# v0.3.0 is the previously published source-only release.
if [[ "$TAG" != v0.3.0 && -z "$APP_SHA" ]]; then
  fail "the release needs $APP_FILE"
fi
[[ "$PUBLISHED" == false ]] || download "$SOURCE_FILE"
verify_source "$SOURCE_SHA"
if [[ -n "$APP_SHA" ]]; then
  [[ "$PUBLISHED" == false ]] || download "$APP_FILE"
  verify_app "$APP_SHA"
fi

if [[ "$WRITE_MANIFEST" == true ]]; then
  write_site_manifest
fi
SUMMARY="Verified Second Wind $TAG: source"
if [[ -n "$APP_SHA" ]]; then SUMMARY="$SUMMARY, universal ad-hoc signed Mac app"; fi
[[ -z "$EXPECTED_COMMIT" ]] || SUMMARY="$SUMMARY from commit $EXPECTED_COMMIT"
[[ "$SKIP_PROVENANCE" == false ]] || SUMMARY="$SUMMARY (provenance NOT checked)"
printf '%s\n' "$SUMMARY"
